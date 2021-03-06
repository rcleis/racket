#lang typed/racket

(require math/functions
         math/special-functions
         math/flonum
         typed/rackunit)

(: ε (Parameterof Float))
(define ε (make-parameter epsilon.0))

(: relative-error<= : Float Float Float -> Boolean)
(define (relative-error<= x correct epsilon)
  (<= (relative-error x correct) epsilon))

;; ---------------------------------------------------------------------------------------------------
;; expm1

(ε (* 2 epsilon.0))

(check-= (flexpm1 1.)      1.71828182845904523536028747135 (ε))
(check-= (flexpm1 1e-5)    0.000010000050000166667083 (ε))
(check-= (flexpm1 1e-10)   1.00000000005000000000166666667e-10 (ε))
(check-= (flexpm1 1e-15)   1.00000000000000050000000000000e-15 (ε))
(check-= (flexpm1 1e-15)   1.00000000000000050000000000000e-15 (ε))
(check-= (flexpm1 -1.)    -0.632120558828557678404476229839 (ε))
(check-= (flexpm1 -1e-10) -9.99999999950000000001666666667e-11 (ε))
(check-= (flexpm1 0.0)     0.0 (ε))

(check-equal? (expm1 0) 0)
(check-= (expm1 1.0)   1.71828182845904523536028747135 (ε))
(check-= (expm1 1.0f0) 1.71828182845904523536028747135f0 (ε))
(check-= (expm1 1/2)   0.648721270700128146848650787814 (ε))

;; ---------------------------------------------------------------------------------------------------
;; factorial and friends

(define fact-table-size 171)
(define simple-cutoff 244)

(: test-factorial : Integer -> Integer)
(define (test-factorial n)
  (if (= n 0) 1 (* n (test-factorial (- n 1)))))

(check-equal? (map factorial (list 0 1 2 3 4 5)) '(1 1 2 6 24 120))
(check-equal? (factorial (+ fact-table-size 1)) (test-factorial (+ fact-table-size 1)))
(check-equal? (factorial (+ simple-cutoff 1)) (test-factorial (+ simple-cutoff 1)))

(check-equal? (binomial 10 3) 120)
(check-equal? (binomial 10 11) 0)
(check-equal? (binomial 10 0) 1)
(check-equal? (binomial 10 10) 1)
(check-equal? (binomial 10 1) 10)
(check-equal? (binomial 10 9) 10)

(check-equal? (permutations 10 3) 720)
(check-equal? (permutations 10 0) 1)
(check-equal? (permutations 10 10) 3628800)
(check-equal? (permutations 0 0) 1)

(check-equal? (multinomial 20 3 4 5 8) 3491888400)

;; ---------------------------------------------------------------------------------------------------
;; gamma

(ε epsilon.0)

(check-equal? (flgamma 0.0) +nan.0)
(check-equal? (flgamma 1.0) 1.0)
(check-equal? (flgamma 2.0) 1.0)
(check-equal? (flgamma 3.0) 2.0)
(check-equal? (flgamma 4.0) 6.0)
(check-= (flgamma -21.5) 1.31844491832155110297694106059e-20 (ε))
(check-true (relative-error<= (flgamma 1e-15) 9.9999999999999942278433509847e14 (ε)))
(check-true (relative-error<= (flgamma 142.5) 2.25990910998653224305124991671e244 (ε)))
(check-equal? (flgamma 172.0) 1.24101807021766782342484052410e309) ; = +inf.0
(check-true (relative-error<= (flgamma -1e-5) -100000.577225555552235029678062 (ε)))

(check-equal? (gamma 0) +nan.0)
(check-equal? (gamma 4) 6)
(check-equal? (gamma 4.0) (flgamma 4.0))
(check-equal? (gamma 4.0f0) (real->single-flonum (flgamma 4.0)))

;; ---------------------------------------------------------------------------------------------------
;; hypot

(ε (* 2 epsilon.0))
  
(check-equal? (flhypot 0. 0.) 0.)
(check-equal? (flhypot 3. 0.) 3.)
(check-equal? (flhypot 3. 4.) 5.)
(check-equal? (flhypot -3. -4.) 5.)
(check-equal? (flhypot 4. 3.) 5.)
(check-= (flhypot 2. 3.) 3.6055512754639892931 (ε))
(check-= (flhypot 3. 2.) 3.6055512754639892931 (ε))
  
(check-equal? (hypot 0 0) 0)
(check-equal? (hypot 3 0) 3)
(check-equal? (hypot 3 4) 5)
(check-equal? (hypot -3 -4) 5)
(check-equal? (hypot 4 3) 5)
(check-= (hypot 2 3) 3.6055512754639892931 (ε))
(check-= (hypot 3 2) 3.6055512754639892931 (ε))

;; ---------------------------------------------------------------------------------------------------
;; logs, exponents, bases, etc.

(check-equal? (fllog/base 2.0 (expt 2.0 5.0)) 5.0)

(check-false (power-of-two? 3))
(check-true (power-of-two? 2))
(check-true (power-of-two? 1))
(check-true (power-of-two? 1/2))
(check-false (power-of-two? 0))
(check-false (power-of-two? -1))
