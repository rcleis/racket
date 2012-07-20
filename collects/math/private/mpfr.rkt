#lang racket/base

(require ffi/unsafe
         ffi/unsafe/cvector
         racket/list
         racket/promise
         (for-syntax racket/base))

(provide
 ;; Parameters
 bf-rounding-mode
 bf-min-precision
 bf-max-precision
 bf-precision
 bf-scientific
 ;; Type predicate
 (rename-out [mpfr? bigfloat?])
 ;; Accessors
 bigfloat-precision
 bigfloat-sign
 bigfloat-exponent
 bigfloat-sig+exp
 bigfloat-significand
 ;; Conversion to and from Real
 float->bigfloat
 integer->bigfloat
 rational->bigfloat
 real->bigfloat
 bigfloat->float
 bigfloat->integer
 bigfloat->rational
 ;; String conversion
 bigfloat->string
 string->bigfloat
 ;; Main constructor
 bf)

;; Arithmetic, comparison, and other functions are provided by the macros that create them

;; ===================================================================================================
;; Setup/takedown

;; All MPFR functions and constants are delayed so that libmpfr and libgmp are loaded on first use.

;; This allows the `math' collection to export `math/bigfloat', and for `math/special-functions' to
;; use MPFR for functions that don't have a Typed Racket implementation yet. On systems without MPFR,
;; no exceptions will be raised unless a user tries to use those functions.

(define libgmp (delay (ffi-lib "libgmp")))
(define-syntax-rule (get-gmp-fun name args ...)
  (let ()
    (define fun (delay (get-ffi-obj name (force libgmp) args ...)))
    (λ xs (apply (force fun) xs))))

(define libmpfr (delay (ffi-lib "libmpfr")))
(define-syntax-rule (get-mpfr-fun name args ...)
  (let ()
    (define fun (delay (get-ffi-obj name (force libmpfr) args ...)))
    (λ xs (apply (force fun) xs))))

(define mpfr-free-cache (get-mpfr-fun 'mpfr_free_cache (_fun -> _void)))

(define scheme-add-atexit-closer
  (get-ffi-obj 'scheme_add_atexit_closer #f
               (_fun (_fun _scheme _pointer _pointer -> _void) -> _void)))

;; Add an exit handler to clear the MPFR constants cache (pi, e, etc.)
;; This isn't working right now: causes a segfault
;; Best guess: MPFR is trying to free memory allocated by Racket
;(scheme-add-atexit-closer (λ (x _1 _2) (mpfr-free-cache)))

;; ===================================================================================================
;; Parameters: rounding mode, bit precision, printing
;; Exponent min and max are not included; they can't be made into parameters, and if we tried they
;; wouldn't be thread-safe.

;; One of 'nearest 'zero 'up 'down
(define bf-rounding-mode (make-parameter 'nearest))

;; minimum precision (1 bit can't be rounded correctly)
(define bf-min-precision 2)
;; maximum precision (the number on 64-bit platforms is ridiculously large)
(define bf-max-precision (- (expt 2 (- (* (ctype-sizeof _long) 8) 1)) 1))

(define bf-precision
  (make-parameter 128 (λ (p) (cond [(p . < . bf-min-precision)  bf-min-precision]
                                   [(p . > . bf-max-precision)  bf-max-precision]
                                   [else  p]))))

;; One of 'always 'never 'shorter
(define bf-scientific (make-parameter 'shorter))

;; ===================================================================================================
;; MPFR types

;; Rounding modes (not all of them, just the useful/well-supported ones)
(define _rnd_t (_enum '(nearest zero up down)))

;; Size header, precision, sign, exponent, limb (part of a bigint)
(define _mp_size_t _long)
(define _prec_t _long)
(define _sign_t _int)
(define _exp_t _long)
(define _limb_t _ulong)

;; Also the size of a union of _mp_size_t and _limb_t (which MPFR uses internally)
(define sizeof-limb_t (ctype-sizeof _limb_t))

;; Number of bits in a limb
(define gmp-limb-bits (* 8 sizeof-limb_t))
;; We don't support "nail" builds, which haven't worked since before GMP 4.3 anyway (a "nail" takes
;; two bits from each limb, and is supposed to speed up carries between limbs on certain systems)

;; The "limbs" of a bigint are an array of _limb_t, where the element 0 is the length of the array
;; in bytes. Entirely reasonable... except that MPFR's bigfloats point at *element 1* for the
;; significand. This ctype converts between a sane cvector and what MPFR expects.
(define _mpfr_limbs
  (make-ctype
   _cvector
   (λ (cvec)
     ;(printf "racket->c~n")
     (define len (cvector-length cvec))
     (cvector-set! cvec 0 (* len sizeof-limb_t))
     (make-cvector* (ptr-add (cvector-ptr cvec) 1 _limb_t) _limb_t (- len 1)))
   (λ (cvec)
     ;(printf "c->racket~n")
     (define len (+ (cvector-length cvec) 1))
     (let ([cvec  (make-cvector* (ptr-add (cvector-ptr cvec) -1 _limb_t) _limb_t len)])
       (unless (= (cvector-ref cvec 0) (* len sizeof-limb_t))
         (error '_mpfr_limbs "internal error: limb cvector not the size in the header"))
       cvec))
   ))

(define (bigfloat-equal? x1 x2 _)
  (define-values (sig1 exp1) (bigfloat-sig+exp x1))
  (define-values (sig2 exp2) (bigfloat-sig+exp x2))
  (and (= sig1 sig2)
       (= exp1 exp2)
       (= (bigfloat-sign x1) (bigfloat-sign x2))))

(define (bigfloat-hash x recur-hash)
  (define-values (sig exp) (bigfloat-sig+exp x))
  (bitwise-xor (recur-hash sig)
               (recur-hash exp)
               (recur-hash (bigfloat-sign x))))

;; mpfr_t: a multi-precision float with rounding (the main data type)
(define-cstruct _mpfr ([prec _prec_t] [sign _sign_t] [exp _exp_t] [d (_gcable _mpfr_limbs)])
  #:property prop:custom-write
  (λ (b port mode) (bigfloat-custom-write b port mode))
  #:property prop:equal+hash
  (list bigfloat-equal? bigfloat-hash bigfloat-hash))

(define mpfr-set-nan (get-mpfr-fun 'mpfr_set_nan (_fun _mpfr-pointer -> _void)))

;; new-mpfr : integer -> _mpfr
;; Creates a new mpfr_t and initializes it, mimicking mpfr_init2. The difference is that our
;; allocated memory is GC'd.
;; (Allowing MPFR to do its own memory management is bad. If we allowed this, Racket wouldn't know
;; how much memory the limbs take. It would assume it's using much less memory than it really is, and
;; become a major memory hog. Feel free to verify this independently.)
(define (new-mpfr prec)
  (define n (add1 (quotient (- prec 1) gmp-limb-bits)))
  (define size (* sizeof-limb_t (+ n 1)))
  ;; Allocate d so that it won't be traced (atomic) or moved (interior)
  (define d (make-cvector* (malloc size 'atomic-interior) _limb_t (+ n 1)))
  (define x (make-mpfr prec 1 0 d))
  ;; Use a finalizer to keep a reference to d as long as x is alive (x's memory isn't traced because
  ;; it's allocated using make-mpfr; this is equivalent to tracing through d only)
  (register-finalizer x (λ (x) d))
  (mpfr-set-nan x)
  x)

;; We always create mpfr_ts using new-mpfr. In doing so, we assume that no mpfr_* function will ever
;; try to reallocate limbs. This is a good assumption because an mpfr_t's precision is fixed from
;; when it's allocated to when it's deallocated. (There's no reason to allocate new limbs for an
;; mpfr_t without changing its precision.)

;; Big integers, big rationals
(define-cstruct _mpz ([alloc _int] [size _int] [limbs _pointer]))
(define-cstruct _mpq ([num _mpz] [den _mpz]))

;; BE CAREFUL WITH THESE. If you make one with make-mpz or make-mpq, DO NOT send it to a function
;; that will reallocate its limbs. In particular, NEVER use it as an output argument. However, you
;; can generally use it as an input argument.

;; MPFR memory management for mpz_t
(define mpz-init (get-gmp-fun '__gmpz_init (_fun _mpz-pointer -> _void)))
(define mpz-clear (get-gmp-fun '__gmpz_clear (_fun _mpz-pointer -> _void)))

;; raw-mpz : -> _mpz-pointer
;; Creates an mpz_t that is managed by the garbage collector, but whose limbs are not. These are
;; always safe to pass to mpz_* functions. We use them for output parameters.
(define (raw-mpz)
  (define x (ptr-ref (malloc _mpz 'atomic-interior) _mpz))
  (mpz-init x)
  x)

;; ===================================================================================================
;; Accessors

(define mpfr-get-prec (get-mpfr-fun 'mpfr_get_prec (_fun _mpfr-pointer -> _prec_t)))
(define mpfr-signbit (get-mpfr-fun 'mpfr_signbit (_fun _mpfr-pointer -> _int)))
(define mpfr-get-exp (get-mpfr-fun 'mpfr_get_exp (_fun _mpfr-pointer -> _exp_t)))
(define mpfr-get-z-2exp
  (with-handlers ([exn?  (λ _ (get-mpfr-fun 'mpfr_get_z_exp
                                            (_fun _mpz-pointer _mpfr-pointer -> _exp_t)))])
    (get-mpfr-fun 'mpfr_get_z_2exp (_fun _mpz-pointer _mpfr-pointer -> _exp_t))))

;; bigfloat-precision : bigfloat -> integer
;; Returns the maximum number of nonzero bits in the significand.
(define bigfloat-precision mpfr-get-prec)

;; bigfloat-sign : bigfloat -> fixnum
;; Returns the sign bit of a bigfloat.
(define bigfloat-sign mpfr-signbit)

;; bigfloat-exponent : bigfloat -> integer
;; Returns the exponent part of a bigfloat.
(define bigfloat-exponent mpfr-get-exp)

;; bigfloat-sig+exp : bigfloat -> integer integer
;; Returns the signed significand and exponent of a bigfloat.
(define (bigfloat-sig+exp x)
  (define z (raw-mpz))
  (define exp (mpfr-get-z-2exp z x))
  (define sig (mpz->integer z))
  (mpz-clear z)
  (values sig exp))

;; bigfloat-significand : bigfloat -> integer
;; Returns just the signed significand of a bigfloat.
(define (bigfloat-significand x)
  (define-values (sig exp) (bigfloat-sig+exp x))
  sig)

;; ===================================================================================================
;; Conversion from Racket data types to bigfloat

(define mpfr-set-d  (get-mpfr-fun 'mpfr_set_d  (_fun _mpfr-pointer _double _rnd_t -> _void)))
(define mpfr-set-si (get-mpfr-fun 'mpfr_set_si (_fun _mpfr-pointer _long _rnd_t -> _void)))
(define mpfr-set-z  (get-mpfr-fun 'mpfr_set_z  (_fun _mpfr-pointer _mpz-pointer _rnd_t -> _void)))
(define mpfr-set-q  (get-mpfr-fun 'mpfr_set_q  (_fun _mpfr-pointer _mpq-pointer _rnd_t -> _void)))

;; integer->size+limbs : integer -> (values integer (listof integer))
;; Returns a cvector of limbs and the size of the limbs. The size is negated when n is negative.
(define (integer->size+limbs n)
  ;; +1 because GMP expects the last limb to be 0
  (define len (+ (ceiling (/ (integer-length n) gmp-limb-bits)) 1))
  (define limbs (make-cvector _limb_t len))
  (define an (abs n))
  (let loop ([i 0])
    (when (i . < . len)
      (define bit (* i gmp-limb-bits))
      (cvector-set! limbs i (bitwise-bit-field an bit (+ bit gmp-limb-bits)))
      (loop (+ i 1))))
  (define size (- len 1))
  (values (if (< n 0) (- size) size)
          (cvector-ptr limbs)))

;; integer->mpz : integer -> _mpz
;; Converts an integer to an _mpz. DO NOT send the result of this as an output argument!
(define (integer->mpz n)
  (let-values ([(size limbs)  (integer->size+limbs n)])
    (make-mpz (abs size) size limbs)))

;; rational->mpq : rational -> _mpz
;; Converts a rational to an _mpq. DO NOT send the result of this as an output argument!
(define (rational->mpq r)
  (make-mpq (integer->mpz (numerator r))
            (integer->mpz (denominator r))))

;; float->bigfloat : float -> bigfloat
;; Converts a Racket inexact real to a bigfloat; rounds if bf-precision < 53.
(define (float->bigfloat value)
  (define x (new-mpfr (bf-precision)))
  (mpfr-set-d x value (bf-rounding-mode))
  x)

;; integer->bigfloat : integer -> bigfloat
;; Converts a Racket integer to a bigfloat; rounds if necessary.
(define (integer->bigfloat value)
  (define x (new-mpfr (bf-precision)))
  (if (fixnum? value)
      (mpfr-set-si x value (bf-rounding-mode))
      (mpfr-set-z x (integer->mpz value) (bf-rounding-mode)))
  x)

;; rational->bigfloat : rational -> bigfloat
;; Converts a Racket rational to a bigfloat; rounds if necessary.
(define (rational->bigfloat value)
  (define x (new-mpfr (bf-precision)))
  (mpfr-set-q x (rational->mpq value) (bf-rounding-mode))
  x)

;; real->bigfloat : real -> bigfloat
;; Converts any real Racket value to a bigfloat; rounds if necessary.
(define (real->bigfloat value)
  (cond [(inexact? value)  (float->bigfloat value)]
        [(integer? value)  (integer->bigfloat value)]
        [(rational? value)  (rational->bigfloat value)]))

;; ===================================================================================================
;; Conversion from mpfr_t to Racket data types

(define mpfr-get-d (get-mpfr-fun 'mpfr_get_d (_fun _mpfr-pointer _rnd_t -> _double)))
(define mpfr-get-z (get-mpfr-fun 'mpfr_get_z (_fun _mpz-pointer _mpfr-pointer _rnd_t -> _int)))
(define mpz-get-si (get-mpfr-fun '__gmpz_get_si (_fun _mpz-pointer -> _long)))
(define mpz-fits-long? (get-mpfr-fun '__gmpz_fits_slong_p (_fun _mpz-pointer -> _int)))

;; size+limbs->integer : integer (listof integer) -> integer
;; Converts a size (which may be negative) and a limb list into an integer.
(define (size+limbs->integer size limbs)
  (define len (abs size))
  (define num
    (let loop ([i 0] [res  0])
      (cond [(i . < . len)
             (define v (ptr-ref limbs _limb_t i))
             (loop (+ i 1) (bitwise-ior res (arithmetic-shift v (* i gmp-limb-bits))))]
            [else  res])))
  (if (negative? size) (- num) num))

;; mpz->integer : _mpz -> integer
;; Converts an mpz_t to an integer.
(define (mpz->integer z)
  (if (zero? (mpz-fits-long? z))
      (size+limbs->integer (mpz-size z) (mpz-limbs z))
      (mpz-get-si z)))

;; bigfloat->float : bigfloat -> float
;; Converts a bigfloat to a Racket float; rounds if necessary.
(define (bigfloat->float x)
  (mpfr-get-d x (bf-rounding-mode)))

;; bigfloat->integer : bigfloat -> integer
;; Converts a bigfloat to a Racket integer; rounds if necessary.
(define (bigfloat->integer x)
  (unless (bfinteger? x) (raise-type-error 'bigfloat->integer "integer Bigfloat" x))
  (define z (raw-mpz))
  (mpfr-get-z z x (bf-rounding-mode))
  (define res (mpz->integer z))
  (mpz-clear z)
  res)

;; bigfloat->rational : bigfloat -> rational
;; Converts a bigfloat to a Racket rational; does not round.
(define (bigfloat->rational x)
  (unless (bffinite? x) (raise-type-error 'bigfloat->rational "finite Bigfloat" x))
  (define-values (sig exp) (bigfloat-sig+exp x))
  (* sig (expt 2 exp)))

;; ===================================================================================================
;; String conversions

;; A "special free" for strings allocated and returned by mpfr_get_str:
(define mpfr-free-str (get-mpfr-fun 'mpfr_free_str (_fun _pointer -> _void)))

(define mpfr-get-str
  (get-mpfr-fun 'mpfr_get_str (_fun _pointer (_cpointer _exp_t) _int _ulong _mpfr-pointer _rnd_t
                                    -> _bytes)))

(define (mpfr-get-string x base rnd)
  (define exp-ptr (cast (malloc _exp_t 'atomic-interior) _pointer (_cpointer _exp_t)))
  (define bs (mpfr-get-str #f exp-ptr base 0 x rnd))
  (define exp (ptr-ref exp-ptr _exp_t))
  (define str (bytes->string/utf-8 bs))
  (mpfr-free-str bs)
  (values exp str))

(define (remove-trailing-zeros str)
  (let loop ([i  (string-length str)])
    (cond [(zero? i)  "0"]
          [(char=? #\0 (string-ref str (sub1 i)))  (loop (sub1 i))]
          [(char=? #\. (string-ref str (sub1 i)))  (substring str 0 (sub1 i))]
          [else  (substring str 0 i)])))

(define (scientific-string exp str)
  (define n (string-length str))
  (cond [(= n 0)  "0"]
        [else
         (define sig (remove-trailing-zeros (format "~a.~a" (substring str 0 1) (substring str 1))))
         (if (= exp 1) sig (format "~ae~a" sig (number->string (- exp 1))))]))

(define (digit-string exp digs)
  (cond [(exp . > . (string-length digs))
         (string-append digs (make-string (- exp (string-length digs)) #\0))]
        [(exp . <= . 0)
         (remove-trailing-zeros
          (string-append "0." (make-string (- exp) #\0) digs))]
        [else
         (remove-trailing-zeros
          (string-append (substring digs 0 exp) "." (substring digs exp)))]))

;; Converts a bigfloat to a Racket string of digits, with a decimal point.
;; Outputs enough digits to exactly recreate the bigfloat using string->bigfloat.
(define (bigfloat->string x)
  (cond
    [(bfzero? x)  (if ((bigfloat-sign x) . < . 0) "-0" "0")]
    [(bfinfinite? x)  (if ((bigfloat-sign x) . < . 0) "-inf.bf" "+inf.bf")]
    [(bfnan? x)   (if ((bigfloat-sign x) . < . 0) "-nan.bf" "+nan.bf")]
    [else
     (define-values (exp str) (mpfr-get-string x 10 'nearest))
     (cond
       [(not str)  (error 'bigfloat->string "string conversion failed for ~e"
                          (number->string (bigfloat->rational x)))]
       [else
        (define-values (sign digs)
          (if (char=? (string-ref str 0) #\-)
              (values "-" (substring str 1))
              (values "" str)))
        (define scientific (bf-scientific))
        (cond [(eq? scientific 'always)  (string-append sign (scientific-string exp digs))]
              [(eq? scientific 'never)   (string-append sign (digit-string exp digs))]
              [else
               (define sstr (scientific-string exp digs))
               (define dstr (digit-string exp digs))
               (cond [((string-length sstr) . < . (string-length dstr))
                      (string-append sign sstr)]
                     [else
                      (string-append sign dstr)])])])]))

;; string->bigfloat : string [integer] -> bigfloat
;; Converts a Racket string to a bigfloat.
(define (string->bigfloat str)
  (define num (string->number (string-append "#e" str) 10))
  (if num (rational->bigfloat num) #f))

(define (bigfloat-custom-write x port mode)
  (write-string
   (cond [(bfzero? x)  (if ((bigfloat-sign x) . < . 0) "-0.bf" "0.bf")]
         [(bffinite? x)
          (define str (bigfloat->string x))
          (cond [(regexp-match #rx"\\.|e" str)
                 (define exp (bigfloat-exponent x))
                 (define prec (bigfloat-precision x))
                 (if ((abs exp) . > . (* prec 2))
                     (format "(bf \"~a\")" str)
                     (format "(bf #e~a)" str))]
                [else  (format "(bf ~a)" str)])]
         [(bfinfinite? x)  (if ((bigfloat-sign x) . < . 0) "-inf.bf" "+inf.bf")]
         [else  (if ((bigfloat-sign x) . < . 0) "-nan.bf" "+nan.bf")])
   port))

;; ===================================================================================================
;; Main bigfloat constructor

;; bf : (or real string) -> bigfloat
(define (bf v)
  (cond [(string? v)  (string->bigfloat v)]
        [else  (real->bigfloat v)]))

;; ===================================================================================================
;; Unary functions

(define-for-syntax 1ary-funs (list))
(provide (for-syntax 1ary-funs))

(define-syntax-rule (provide-1ary-fun name c-name)
  (begin
    (define cfun (get-mpfr-fun c-name (_fun (y : _mpfr-pointer) _mpfr-pointer _rnd_t -> _int)))
    (define (name x)
      (define y (new-mpfr (bf-precision)))
      (cfun y x (bf-rounding-mode))
      y)
    (provide name)
    (begin-for-syntax (set! 1ary-funs (cons #'name 1ary-funs)))))

(define-syntax-rule (provide-1ary-funs [name c-name] ...)
  (begin (provide-1ary-fun name c-name) ...))

(provide-1ary-funs
 [bfsqr 'mpfr_sqr]
 [bfsqrt 'mpfr_sqrt]
 [bf1/sqrt 'mpfr_rec_sqrt]
 [bfcbrt 'mpfr_cbrt]
 [bfneg 'mpfr_neg]
 [bfabs 'mpfr_abs]
 [bflog 'mpfr_log]
 [bflog2 'mpfr_log2]
 [bflog10 'mpfr_log10]
 [bfexp 'mpfr_exp]
 [bfexp2 'mpfr_exp2]
 [bfexp10 'mpfr_exp10]
 [bfcos 'mpfr_cos]
 [bfsin 'mpfr_sin]
 [bftan 'mpfr_tan]
 [bfsec 'mpfr_sec]
 [bfcsc 'mpfr_csc]
 [bfcot 'mpfr_cot]
 [bfacos 'mpfr_acos]
 [bfasin 'mpfr_asin]
 [bfatan 'mpfr_atan]
 [bfcosh 'mpfr_cosh]
 [bfsinh 'mpfr_sinh]
 [bftanh 'mpfr_tanh]
 [bfsech 'mpfr_sech]
 [bfcsch 'mpfr_csch]
 [bfcoth 'mpfr_coth]
 [bfacosh 'mpfr_acosh]
 [bfasinh 'mpfr_asinh]
 [bfatanh 'mpfr_atanh]
 [bfeint 'mpfr_eint]
 [bfli2 'mpfr_li2]
 [bfgamma 'mpfr_gamma]
 [bflog-gamma 'mpfr_lngamma]
 [bfdigamma 'mpfr_digamma]
 [bfzeta 'mpfr_zeta]
 [bferf 'mpfr_erf]
 [bferfc 'mpfr_erfc]
 [bfj0 'mpfr_j0]
 [bfj1 'mpfr_j1]
 [bfy0 'mpfr_y0]
 [bfy1 'mpfr_y1]
 [bfrint 'mpfr_rint]
 [bffrac 'mpfr_frac])

(define-syntax-rule (provide-1ary-fun/noround name c-name)
  (begin
    (define cfun (get-mpfr-fun c-name (_fun _mpfr-pointer _mpfr-pointer _rnd_t -> _int)))
    (define (name x)
      (define y (new-mpfr (bf-precision)))
      (cfun y x (bf-rounding-mode))
      y)
    (provide name)
    (begin-for-syntax (set! 1ary-funs (cons #'name 1ary-funs)))))

(provide-1ary-fun/noround bfceiling 'mpfr_ceil)
(provide-1ary-fun/noround bffloor 'mpfr_floor)
(provide-1ary-fun/noround bfround 'mpfr_round)
(provide-1ary-fun/noround bftruncate 'mpfr_trunc)

(define-for-syntax 1ary2-funs (list))
(provide (for-syntax 1ary2-funs))

(define-syntax-rule (provide-1ary2-fun name c-name)
  (begin
    (define cfun
      (get-mpfr-fun c-name (_fun _mpfr-pointer _mpfr-pointer _mpfr-pointer _rnd_t -> _int)))
    (define (name x)
      (define y (new-mpfr (bf-precision)))
      (define z (new-mpfr (bf-precision)))
      (cfun y z x (bf-rounding-mode))
      (values y z))
    (provide name)
    (begin-for-syntax (set! 1ary2-funs (cons #'name 1ary2-funs)))))

(provide-1ary2-fun bfsin+cos 'mpfr_sin_cos)
(provide-1ary2-fun bfsinh+cosh 'mpfr_sinh_cosh)
(provide-1ary2-fun bfmodf 'mpfr_modf)

;; ===================================================================================================
;; Unary predicates

(define-for-syntax 1ary-preds (list))
(provide (for-syntax 1ary-preds))

(define-syntax-rule (provide-1ary-pred name c-name)
  (begin
    (define cfun (get-mpfr-fun c-name (_fun _mpfr-pointer -> _int)))
    (define (name x) (not (zero? (cfun x))))
    (provide name)
    (begin-for-syntax (set! 1ary-preds (cons #'name 1ary-preds)))))

(define-syntax-rule (provide-1ary-preds [name c-name] ...)
  (begin (provide-1ary-pred name c-name) ...))

(provide-1ary-preds
 [bfnan?  'mpfr_nan_p]
 [bfinfinite?  'mpfr_inf_p]
 [bffinite? 'mpfr_number_p]
 [bfinteger? 'mpfr_integer_p]
 [bfzero? 'mpfr_zero_p])

(define (bfpositive? x)
  (bf> x (force 0.bf)))

(define (bfnegative? x)
  (bf< x (force 0.bf)))

(define (bfeven? x)
  (unless (bfinteger? x) (raise-type-error 'bfeven? "bfinteger?" x))
  (even? (bigfloat->integer x)))

(define (bfodd? x)
  (unless (bfinteger? x) (raise-type-error 'bfodd? "bfinteger?" x))
  (odd? (bigfloat->integer x)))

(provide bfpositive? bfnegative? bfeven? bfodd?)
(begin-for-syntax
  (set! 1ary-preds (append (list #'bfpositive? #'bfnegative? #'bfeven? #'bfodd?)
                           1ary-preds)))

;; ===================================================================================================
;; Binary functions

(define-for-syntax 2ary-funs (list))
(provide (for-syntax 2ary-funs))

(define-syntax-rule (provide-2ary-fun name c-name)
  (begin
    (define cfun
      (get-mpfr-fun c-name (_fun _mpfr-pointer _mpfr-pointer _mpfr-pointer _rnd_t -> _int)))
    (define (name x1 x2)
      (define y (new-mpfr (bf-precision)))
      (cfun y x1 x2 (bf-rounding-mode))
      y)
    (provide name)
    (begin-for-syntax (set! 2ary-funs (cons #'name 2ary-funs)))))

(define-syntax-rule (provide-2ary-funs [name c-name] ...)
  (begin (provide-2ary-fun name c-name) ...))

(provide-2ary-funs
 [bf+ 'mpfr_add]
 [bf- 'mpfr_sub]
 [bf* 'mpfr_mul]
 [bf/ 'mpfr_div]
 [bfexpt 'mpfr_pow]
 [bfmax 'mpfr_max]
 [bfmin 'mpfr_min]
 [bfatan2 'mpfr_atan2]
 [bfhypot 'mpfr_hypot]
 [bfagm 'mpfr_agm])

(define mpfr-jn (get-mpfr-fun 'mpfr_jn (_fun _mpfr-pointer _long _mpfr-pointer _rnd_t -> _int)))
(define mpfr-yn (get-mpfr-fun 'mpfr_yn (_fun _mpfr-pointer _long _mpfr-pointer _rnd_t -> _int)))

(define (bfjn n x)
  (unless (fixnum? n) (raise-type-error 'bfjn "Fixnum" 0 n x))
  (define y (new-mpfr (bf-precision)))
  (mpfr-jn y n x (bf-rounding-mode))
  y)

(define (bfyn n x)
  (unless (fixnum? n) (raise-type-error 'bfyn "Fixnum" 0 n x))
  (define y (new-mpfr (bf-precision)))
  (mpfr-yn y n x (bf-rounding-mode))
  y)

(define mpfr-set-exp (get-mpfr-fun 'mpfr_set_exp (_fun _mpfr-pointer _exp_t -> _int)))
(define mpfr-set (get-mpfr-fun 'mpfr_set (_fun _mpfr-pointer _mpfr-pointer _rnd_t -> _int)))

(define (bfshift x n)
  (unless (fixnum? n) (raise-type-error 'bfshift "Fixnum" 1 x n))
  (cond [(bfzero? x)  x]
        [(not (bffinite? x))  x]
        [else  (define exp (mpfr-get-exp x))
               (define y (new-mpfr (bf-precision)))
               (mpfr-set y x (bf-rounding-mode))
               (mpfr-set-exp y (+ exp n))
               y]))

(provide bfjn bfyn bfshift)

;; ===================================================================================================
;; Binary predicates

(define-for-syntax 2ary-preds (list))
(provide (for-syntax 2ary-preds))

(define-syntax-rule (provide-2ary-pred name c-name)
  (begin (define cfun (get-mpfr-fun c-name (_fun _mpfr-pointer _mpfr-pointer -> _int)))
         (define (name x1 x2)
           (not (zero? (cfun x1 x2))))
         (provide name)
         (begin-for-syntax (set! 2ary-preds (cons #'name 2ary-preds)))))

(define-syntax-rule (provide-2ary-preds [name c-name] ...)
  (begin (provide-2ary-pred name c-name) ...))

(provide-2ary-preds
 [bf> 'mpfr_greater_p]
 [bf>= 'mpfr_greaterequal_p]
 [bf< 'mpfr_less_p]
 [bf<= 'mpfr_lessequal_p]
 [bf= 'mpfr_equal_p])

;; ===================================================================================================
;; 0-arity functions (variable-precision constants)

(define-for-syntax 0ary-funs (list))
(provide (for-syntax 0ary-funs))

(define-syntax-rule (provide-0ary-fun name c-name)
  (begin
    (define cfun (get-mpfr-fun c-name (_fun _mpfr-pointer _rnd_t -> _int)))
    (define (name)
      (define y (new-mpfr (bf-precision)))
      (cfun y (bf-rounding-mode))
      y)
    (provide name)
    (begin-for-syntax (set! 0ary-funs (cons #'name 0ary-funs)))))

(define-syntax-rule (provide-0ary-funs [name c-name] ...)
  (begin (provide-0ary-fun name c-name) ...))

(provide-0ary-funs
 [log2.bf 'mpfr_const_log2]
 [pi.bf 'mpfr_const_pi]
 [euler.bf 'mpfr_const_euler]
 [catalan.bf 'mpfr_const_catalan])

(define-for-syntax consts (list))
(provide (for-syntax consts))

(define-syntax-rule (define-bf-constant name expr)
  (begin
    (define lazy-name (delay (parameterize ([bf-precision  bf-min-precision])
                               expr)))
    (define-syntax (name stx)
      (syntax-case stx ()
        [(_ e (... ...))  (syntax/loc stx ((force lazy-name) e (... ...)))]
        [_  (syntax/loc stx (force lazy-name))]))))

(define-values (-inf.bf -0.bf 0.bf +inf.bf +nan.bf -nan.bf)
  (parameterize ([bf-precision  bf-min-precision])
    (values (delay (float->bigfloat -inf.0))
            (delay (float->bigfloat -0.0))
            (delay (float->bigfloat  0.0))
            (delay (float->bigfloat +inf.0))
            (delay (float->bigfloat +nan.0))
            (delay (bfneg (float->bigfloat +nan.0))))))

(provide -inf.bf -0.bf 0.bf +inf.bf +nan.bf -nan.bf)
(begin-for-syntax
  (set! consts (list* #'-inf.bf #'-0.bf #'0.bf #'+inf.bf #'+nan.bf #'-nan.bf consts)))

;; ===================================================================================================

;(define mpfr-set-m (get-mpfr-fun 'mpfr_set (_fun _mpfr-pointer _mpfr-pointer _rnd_t -> _int)))