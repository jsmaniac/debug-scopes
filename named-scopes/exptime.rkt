#lang racket

(require (for-template '#%kernel)
         type-expander/debug-scopes
         racket/syntax
         racket/struct
         type-expander/debug-scopes)

(provide make-named-scope
         named-transformer
         (rename-out [-syntax-local-introduce syntax-local-introduce]))

(define (use-site-context?)
  (not (bound-identifier=? (syntax-local-introduce #'here)
                           (syntax-local-identifier-as-binding
                            (syntax-local-introduce #'here)))))

(define (make-named-scope nm)
  (define name (if (symbol? nm) nm (string->symbol nm)))
  (define E1
    (local-expand (datum->syntax #f
                                 `(,#'module
                                   ,name
                                   debug-scopes/named-scopes/dummy-lang
                                   '#%kernel
                                   list))
                  'top-level
                  (list)))
  (define/with-syntax (_module _name _lang (_modbeg (_#%require QK1) Body1)) E1)
  (define QK (datum->syntax #'QK1 'qk-sym))
  (define Body (datum->syntax #'Body1 'body-sym))
  (define Zero (datum->syntax #f 'zero))
  (define ΔBody (make-syntax-delta-introducer Body Zero))
  (define QK-Body (ΔBody QK 'remove))
  (define ΔQK-Body (make-syntax-delta-introducer QK-Body Zero))
  (define QK-rest (ΔQK-Body QK 'remove))
  (define named-scope (make-syntax-delta-introducer QK-rest Zero))
  named-scope)

(define ((has-scope scope) stx)
  (and (identifier? stx)
       (bound-identifier=? stx (scope stx 'add))))

(define (replace-scope old new)
  (define (replace e)
    (cond
      [(syntax? e)
       (datum->syntax (if ((has-scope old) e)
                          (new (old e 'remove) 'add)
                          e)
                      (replace (syntax-e e))
                      e
                      e)]
      [(pair? e) (cons (replace (car e)) (replace (cdr e)))]
      [(vector? e) (list->vector (replace (vector->list e)))]
      [(hash? e)
       (cond [(hash-eq? e) (make-hasheq (replace (hash->list e)))]
             [(hash-eqv? e) (make-hasheqv (replace (hash->list e)))]
             [(hash-equal? e) (make-hash (replace (hash->list e)))]
             [else e])]
      [(prefab-struct-key e)
       => (λ (k)
            (apply make-prefab-struct k (replace (struct->list e))))]
      [else e]))
  replace)

(define (deep-has-scope sc)
  (define (scan e)
    (cond
      [(syntax? e) (or ((has-scope sc) e) (scan (syntax-e e)))]
      [(pair? e) (or (scan (car e)) (scan (cdr e)))]
      [(vector? e) (scan (vector->list e))]
      [(hash? e) (scan (hash->list e))]
      [(prefab-struct-key e) (scan (struct->list e))]
      [else #f]))
  scan)

(define (old-macro-scope)
  (make-syntax-delta-introducer
   (syntax-local-identifier-as-binding
    (syntax-local-introduce
     (datum->syntax #f 'zero)))
   (datum->syntax #f 'zero)))

(define (old-use-site-scope)
  (make-syntax-delta-introducer
   ((old-macro-scope) (syntax-local-introduce (datum->syntax #f 'zero)) 'remove)
   (datum->syntax #f 'zero)))

(define (convert-macro-scopes stx)
  (if (sli-scopes)
      (let* ([macro (car (sli-scopes))]
             [use-site (cdr (sli-scopes))]
             [old-macro (old-macro-scope)]
             [old-use (old-use-site-scope)])
        ((compose (if (use-site-context?)
                      (replace-scope old-use use-site)
                      (λ (x) x))
                  (replace-scope old-macro macro))
         stx))
      ;; Otherwise leave unchanged.
      stx))

(define ((named-transformer-wrap name f) stx)
  (parameterize ([sli-scopes
                  (cons (make-named-scope (format "macro: ~a" name))
                        (if (use-site-context?)
                            (make-named-scope (format "use-site: ~a" name))
                            (make-syntax-delta-introducer
                             (datum->syntax #f 'zero)
                             (datum->syntax #f 'zero))))])
    ;;; TODO: we should detect the presence of old-* here instead, and 'add them
    (displayln (+scopes stx))
    (displayln (use-site-context?))
    (displayln (+scopes (convert-macro-scopes stx)))
    (let ([res (f (convert-macro-scopes stx))])
      (when ((deep-has-scope (old-macro-scope)) res)
        (error (format "original macro scope appeared within the result of a named transformer: ~a\n~a\n~a"
                       res
                       (+scopes res)
                       (with-output-to-string (λ () (print-full-scopes))))))
      (when (and (use-site-context?)
                 ((deep-has-scope (old-use-site-scope)) res))
        (error "original use-site scope appeared within the result of a named transformer"))
      (let* ([/mm ((car (sli-scopes)) res 'flip)]
             [/mm/uu (if (use-site-context?) ((cdr (sli-scopes)) /mm 'flip) /mm)]
             [/mm/uu+m ((old-macro-scope) /mm/uu 'add)])
        (if (use-site-context?)
            ((old-use-site-scope) /mm/uu+m 'add)
            /mm/uu+m)))))

(define-syntax-rule (named-transformer (name stx) . body)
  (named-transformer-wrap 'name (λ (stx) . body)))

(define sli-scopes (make-parameter #f))

(define (-syntax-local-introduce stx)
  (if (sli-scopes)
      ((cdr (sli-scopes)) ((car (sli-scopes)) stx 'flip)
                          'flip)
      (syntax-local-introduce stx)))

(define (-syntax-local-identifier-as-binding stx)
  (if (and (sli-scopes) (use-site-context?))
      ((cdr (sli-scopes)) stx 'flip)
      (syntax-local-introduce stx)))