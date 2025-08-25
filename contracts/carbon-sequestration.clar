;; Carbon Sequestration Measurement Contract
;; Quantifies the amount of carbon dioxide stored in managed forests

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u500))
(define-constant ERR-MEASUREMENT-NOT-FOUND (err u501))
(define-constant ERR-INVALID-DATA (err u502))
(define-constant ERR-CREDIT-NOT-FOUND (err u503))
(define-constant ERR-INSUFFICIENT-CREDITS (err u504))

;; Data Variables
(define-data-var next-measurement-id uint u1)
(define-data-var next-credit-id uint u1)

;; Data Maps
(define-map carbon-measurements
  { measurement-id: uint }
  {
    plot-id: uint,
    measurement-date: uint,
    co2-sequestered-tons: uint,
    measurement-method: (string-ascii 50),
    verifier: principal,
    verified: bool,
    baseline-measurement: bool,
    notes: (string-ascii 200)
  }
)

(define-map carbon-credits
  { credit-id: uint }
  {
    plot-id: uint,
    measurement-id: uint,
    credits-issued: uint,
    credits-available: uint,
    issue-date: uint,
    vintage-year: uint,
    price-per-credit: uint,
    issuer: principal
  }
)

(define-map credit-transactions
  { transaction-id: uint }
  {
    credit-id: uint,
    from-party: principal,
    to-party: principal,
    credits-transferred: uint,
    price-per-credit: uint,
    transaction-date: uint
  }
)

(define-map authorized-verifiers principal bool)
(define-map plot-baselines
  { plot-id: uint }
  { baseline-co2: uint, baseline-date: uint }
)

(define-data-var next-transaction-id uint u1)

;; Authorization Functions
(define-public (add-authorized-verifier (verifier principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-verifiers verifier true))
  )
)

;; Carbon Measurement Management
(define-public (record-carbon-measurement
  (plot-id uint)
  (co2-sequestered-tons uint)
  (measurement-method (string-ascii 50))
  (is-baseline bool)
  (notes (string-ascii 200))
)
  (let
    (
      (measurement-id (var-get next-measurement-id))
      (is-authorized (default-to false (map-get? authorized-verifiers tx-sender)))
    )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! (> co2-sequestered-tons u0) ERR-INVALID-DATA)

    ;; Record measurement
    (map-set carbon-measurements
      { measurement-id: measurement-id }
      {
        plot-id: plot-id,
        measurement-date: block-height,
        co2-sequestered-tons: co2-sequestered-tons,
        measurement-method: measurement-method,
        verifier: tx-sender,
        verified: false,
        baseline-measurement: is-baseline,
        notes: notes
      }
    )

    ;; Set baseline if this is a baseline measurement
    (if is-baseline
      (map-set plot-baselines
        { plot-id: plot-id }
        { baseline-co2: co2-sequestered-tons, baseline-date: block-height }
      )
      true
    )

    (var-set next-measurement-id (+ measurement-id u1))
    (ok measurement-id)
  )
)

(define-public (verify-carbon-measurement
  (measurement-id uint)
  (verification-notes (string-ascii 200))
)
  (let
    (
      (measurement-data (unwrap! (map-get? carbon-measurements { measurement-id: measurement-id }) ERR-MEASUREMENT-NOT-FOUND))
      (is-authorized (default-to false (map-get? authorized-verifiers tx-sender)))
    )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq tx-sender (get verifier measurement-data))) ERR-NOT-AUTHORIZED)

    (ok (map-set carbon-measurements
      { measurement-id: measurement-id }
      (merge measurement-data { verified: true })
    ))
  )
)

;; Carbon Credit Management
(define-public (issue-carbon-credits
  (plot-id uint)
  (measurement-id uint)
  (credits-to-issue uint)
  (vintage-year uint)
  (price-per-credit uint)
)
  (let
    (
      (credit-id (var-get next-credit-id))
      (measurement-data (unwrap! (map-get? carbon-measurements { measurement-id: measurement-id }) ERR-MEASUREMENT-NOT-FOUND))
      (baseline-data (map-get? plot-baselines { plot-id: plot-id }))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (get verified measurement-data) ERR-INVALID-DATA)
    (asserts! (is-eq (get plot-id measurement-data) plot-id) ERR-INVALID-DATA)
    (asserts! (> credits-to-issue u0) ERR-INVALID-DATA)

    ;; Calculate maximum credits based on CO2 sequestration above baseline
    (let
      (
        (current-co2 (get co2-sequestered-tons measurement-data))
        (baseline-co2 (match baseline-data
          baseline (get baseline-co2 baseline)
          u0
        ))
        (additional-co2 (if (> current-co2 baseline-co2) (- current-co2 baseline-co2) u0))
      )
      (asserts! (<= credits-to-issue additional-co2) ERR-INVALID-DATA)

      (map-set carbon-credits
        { credit-id: credit-id }
        {
          plot-id: plot-id,
          measurement-id: measurement-id,
          credits-issued: credits-to-issue,
          credits-available: credits-to-issue,
          issue-date: block-height,
          vintage-year: vintage-year,
          price-per-credit: price-per-credit,
          issuer: tx-sender
        }
      )

      (var-set next-credit-id (+ credit-id u1))
      (ok credit-id)
    )
  )
)

(define-public (transfer-carbon-credits
  (credit-id uint)
  (to-party principal)
  (credits-to-transfer uint)
  (agreed-price uint)
)
  (let
    (
      (credit-data (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR-CREDIT-NOT-FOUND))
      (transaction-id (var-get next-transaction-id))
    )
    (asserts! (> credits-to-transfer u0) ERR-INVALID-DATA)
    (asserts! (<= credits-to-transfer (get credits-available credit-data)) ERR-INSUFFICIENT-CREDITS)

    ;; Update available credits
    (map-set carbon-credits
      { credit-id: credit-id }
      (merge credit-data {
        credits-available: (- (get credits-available credit-data) credits-to-transfer)
      })
    )

    ;; Record transaction
    (map-set credit-transactions
      { transaction-id: transaction-id }
      {
        credit-id: credit-id,
        from-party: tx-sender,
        to-party: to-party,
        credits-transferred: credits-to-transfer,
        price-per-credit: agreed-price,
        transaction-date: block-height
      }
    )

    (var-set next-transaction-id (+ transaction-id u1))
    (ok transaction-id)
  )
)

;; Read-only Functions
(define-read-only (get-carbon-measurement (measurement-id uint))
  (map-get? carbon-measurements { measurement-id: measurement-id })
)

(define-read-only (get-carbon-credits (credit-id uint))
  (map-get? carbon-credits { credit-id: credit-id })
)

(define-read-only (get-plot-baseline (plot-id uint))
  (map-get? plot-baselines { plot-id: plot-id })
)

(define-read-only (get-credit-transaction (transaction-id uint))
  (map-get? credit-transactions { transaction-id: transaction-id })
)

(define-read-only (calculate-sequestration-rate (plot-id uint) (measurement-id-1 uint) (measurement-id-2 uint))
  (let
    (
      (measurement-1 (unwrap! (map-get? carbon-measurements { measurement-id: measurement-id-1 }) (err u0)))
      (measurement-2 (unwrap! (map-get? carbon-measurements { measurement-id: measurement-id-2 }) (err u0)))
    )
    (if (and (is-eq (get plot-id measurement-1) plot-id)
             (is-eq (get plot-id measurement-2) plot-id)
             (> (get measurement-date measurement-2) (get measurement-date measurement-1)))
      (let
        (
          (co2-diff (- (get co2-sequestered-tons measurement-2) (get co2-sequestered-tons measurement-1)))
          (time-diff (- (get measurement-date measurement-2) (get measurement-date measurement-1)))
        )
        (ok (/ co2-diff time-diff))
      )
      (err u0)
    )
  )
)

(define-read-only (get-total-measurements)
  (- (var-get next-measurement-id) u1)
)

(define-read-only (get-total-credits)
  (- (var-get next-credit-id) u1)
)
