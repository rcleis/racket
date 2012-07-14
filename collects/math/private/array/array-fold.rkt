#lang typed/racket/base

(require racket/unsafe/ops
         "array-struct.rkt"
         "utils.rkt")

(provide array-axis-fold
         array-axis-sum
         array-axis-prod
         array-axis-min
         array-axis-max
         flarray-axis-sum
         flarray-axis-prod)

(: array-axis-fold (All (A B) ((A B -> B) B (Array A) Integer -> (lazy-array B))))
(define (array-axis-fold f init arr k)
  (let ([arr  (array-lazy arr)])
    (define ds (unsafe-array-shape arr))
    (define dims (vector-length ds))
    (cond
      [(= dims 0)  (raise-type-error 'array-sum "Array with at least one axis" 0 arr k)]
      [(or (0 . > . k) (k . >= . dims))
       (raise-type-error 'array-sum (format "Index less than ~a" dims) 1 arr k)]
      [else
       (define dk (unsafe-vector-ref ds k))
       (define new-ds (unsafe-vector-remove ds k))
       (define proc (unsafe-array-proc arr))
       (unsafe-lazy-array
        new-ds (λ: ([js : (Vectorof Index)])
                 (define old-js (unsafe-vector-insert js k 0))
                 (let: loop : B ([i : Nonnegative-Fixnum  0] [acc : B  init])
                   (cond [(i . < . dk)  (unsafe-vector-set! old-js k i)
                                        (loop (+ i 1) (f (proc old-js) acc))]
                         [else  acc]))))])))

(: array-axis-sum  (case-> ((Array Real)   Integer -> (lazy-array Real))
                           ((Array Number) Integer -> (lazy-array Number))))
(: array-axis-prod (case-> ((Array Real)   Integer -> (lazy-array Real))
                           ((Array Number) Integer -> (lazy-array Number))))

(: array-axis-min (case-> ((Array Float) Integer -> (lazy-array Float))
                          ((Array Real)  Integer -> (lazy-array Real))))
(: array-axis-max (case-> ((Array Float) Integer -> (lazy-array Float))
                          ((Array Real)  Integer -> (lazy-array Real))))

(: flarray-axis-sum  ((Array Float) Integer -> (lazy-array Float)))
(: flarray-axis-prod ((Array Float) Integer -> (lazy-array Float)))

(define (array-axis-sum  arr k) (array-axis-fold + 0 arr k))
(define (array-axis-prod arr k) (array-axis-fold * 1 arr k))

(define (array-axis-min  arr k) (array-axis-fold min +inf.0 arr k))
(define (array-axis-max  arr k) (array-axis-fold max -inf.0 arr k))

(define (flarray-axis-sum  arr k) (array-axis-fold unsafe-fl+ 0.0 arr k))
(define (flarray-axis-prod arr k) (array-axis-fold unsafe-fl* 1.0 arr k))