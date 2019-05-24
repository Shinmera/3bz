(in-package 3bz)

(defstruct (zlib-state (:conc-name zs-)
                       (:include deflate-state))
  (zlib-state :header)
  (compression-method nil)
  (window-size 0)
  (dict-id nil)
  (compression-level :default)
  ;; checksum state
  (s1 1 :type (unsigned-byte 16))
  (s2 0 :type (unsigned-byte 16)))

(defun check-zlib-header (cmf flg &key (errorp t))
  (let* ((cm (ldb (byte 4 0) cmf))
         (cinfo (ldb (byte 4 4) cmf))
         (check (zerop (mod (+ (* cmf 256) flg) 31)))
         (dict (logbitp 5 flg))
         (level (ldb (byte 2 6) flg)))
    (when (not check)
      (when errorp
        (error "invalid zlib header checksum")))
    (if (= cm 8)
        (setf cm :deflate)
        (progn
          (when errorp
            (error "invalid zlib compression type"))
          (setf check nil)))
    (when (> cinfo 7)
      (when errorp
        (error "invalid window size in zlib header"))
      (setf check nil))
    (when dict
      (when errorp
        (error "preset dictionary not supported yet"))
      (setf check nil))
    (values check cm cinfo dict level)))

(defun adler32 (buf end s1 s2)
  (declare (type octet-vector buf)
           (type (unsigned-byte 16) s1 s2)
           (optimize speed))
  ;; with 32bit accumulators, we need to do the MOD every 5552 adds.
  ;; with 64bit, every 380368439.  formula = (+ (* (1+ n) 65520) (* (/
  ;; (* n (1+ n)) 2) 255))
  (let* ((unroll 16) ;; adjust UNROLL call below if changing this
         (chunk-size ;(* unroll (floor 5552 unroll))
           (* unroll (floor 380368439 unroll)))
         (s1 s1)
         (s2 s2))
    (declare (type (unsigned-byte 64) s1 s2))

    (assert (<= end (length buf)))
    (unless (zerop end)
      (loop
        with start fixnum = 0
        for c fixnum = (max 0
                            (min chunk-size
                                 (- end start)))
        do (macrolet ((a (i)
                        `(progn
                           (setf s1 (ldb (byte 64 0)
                                         (+ s1
                                            (locally
                                                (declare (optimize (safety 0)))
                                              (aref buf ,i)))))
                           (setf s2 (ldb (byte 64 0) (+ s2 s1)))))
                      (unroll (n)
                        `(progn
                           ,@(loop for x below n
                                   collect `(a (+ i ,x))))))
             (if (and (zerop (mod c unroll))
                      (plusp c))
                 (loop for i of-type fixnum from start
                         below (min (+ start c)
                                    (* unroll (floor (length buf) unroll)))
                       by unroll
                       do (unroll 16)) ;; adjust variable above if changing
                 (loop for i fixnum from start below (min (+ start c)
                                                          (length buf))
                       do (a i))))
           (incf start c)
           (setf s1 (mod s1 +adler32-prime+)
                 s2 (mod s2 +adler32-prime+))
        while (< start end)))
    (values s1 s2)))

(defun decompress-zlib (read-context state)
  (check-type state zlib-state)
  ;; fixme: avoid duplication with these from deflate
  (with-reader-contexts (read-context)
    (with-accessors ((input-underrun zs-input-underrun)
                     (zlib-state zs-zlib-state)
                     (partial-bits zs-partial-bits)
                     (bits-remaining zs-bits-remaining)
                     (finished zs-finished)
                     (window-size zs-window-size)
                     (compression-level zs-compression-level)
                     (dict-id zs-dict-id)
                     (compression-method zs-compression-method)
                     (output-offset zs-output-offset)
                     (output-overflow zs-output-overflow))
        state
      (labels ((%fill-bits32 (n)
                 (multiple-value-bind (input octets)
                     (word32)
                   (declare (type (mod 5) octets))
                   (setf partial-bits
                         (logior
                          (ash (ldb (byte 32 0) input)
                               (min 32 bits-remaining))
                          partial-bits))
                   (incf bits-remaining (* 8 octets))
                   (>= bits-remaining n)))
               (%bits (n)
                 (prog1 (ldb (byte n 0) partial-bits)
                   (setf partial-bits (ash partial-bits (- n)))
                   (decf bits-remaining n)))
               (byte-align ()
                 (let ((r (mod bits-remaining 8)))
                   (unless (zerop r)
                     (setf partial-bits (ash partial-bits (- r)))
                     (decf bits-remaining r))))
               ;; these are called from 2 places to allow finishing in
               ;; single call, while trying to minimize conditionals
               ;; in hot path when working with input/output in chunks
               (dictid ()
                 (error "preset dictionary not supported yet"))
               (adler ()
                 (when (and (< bits-remaining 32)
                            (not (%fill-bits32 32)))
                   (setf input-underrun t)
                   (return-from decompress-zlib
                     output-offset))
                 (let ((adler32 (logior (ash (%bits 8) 24)
                                        (ash (%bits 8) 16)
                                        (ash (%bits 8) 8)
                                        (ash (%bits 8) 0)))
                       (calculated (logior (zs-s1 state)
                                           (ash (zs-s2 state) 16))))
                   (declare (optimize (speed 1)))
                   ;;(format t "checksum = ~8,'0x~%" adler32)
                   ;;(format t "calculated = ~8,'0x~%" calculated)
                   (assert (= adler32 calculated))
                   (setf finished t)))
               (update-checksum ()
                 (declare (optimize speed))
                 (setf (values (zs-s1 state) (zs-s2 state))
                       (adler32 (zs-output-buffer state)
                                output-offset
                                (zs-s1 state) (zs-s2 state)))))
        (declare (inline %fill-bits32 %bits byte-align)
                 (optimize (speed 1)))
        (setf input-underrun nil)
        (when zlib-state
          (case zlib-state
            (:header
             (when (and (< bits-remaining 16)
                        (not (%fill-bits32 16)))
               (setf input-underrun t)
               (return-from decompress-zlib 0))
             (multiple-value-bind (ok cm cinfo dict level)
                 (check-zlib-header (%bits 8) (%bits 8))
               (declare (ignore ok))
               (setf compression-level
                     (aref #(:fastest :fast :default :maximum) level))
               (setf window-size (expt 2 (+ cinfo 8)))2
               (setf compression-method cm)
               (setf dict-id dict)
               (when dict
                 (setf zlib-state :header2)
                 (dictid))
               (format t "zlib header: method ~s, level ~s, window ~s, dict ~s~%"
                       compression-method compression-level window-size dict-id)))
            (:header2
             (dictid))
            (:adler
             (adler)))
          (setf zlib-state nil))
        (unless zlib-state
          (print (decompress read-context state))
          (when (or finished output-overflow)
            (update-checksum))
          (when finished
            (byte-align)
            (setf zlib-state :adler)
            (setf finished nil)))
        (when (eql :adler zlib-state)
          (adler))
        output-offset))))
