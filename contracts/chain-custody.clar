;; Chain of Custody Monitoring Contract
;; Tracks the movement of timber from forest to consumer

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-TRANSFER-NOT-FOUND (err u401))
(define-constant ERR-INVALID-DATA (err u402))
(define-constant ERR-BATCH-NOT-FOUND (err u403))
(define-constant ERR-INVALID-CUSTODY (err u404))

;; Data Variables
(define-data-var next-transfer-id uint u1)

;; Data Maps
(define-map custody-transfers
  { transfer-id: uint }
  {
    batch-id: uint,
    from-party: principal,
    to-party: principal,
    transfer-date: uint,
    location: (string-ascii 100),
    transport-method: (string-ascii 50),
    condition-notes: (string-ascii 200),
    verified: bool,
    verifier: (optional principal)
  }
)

(define-map current-custody
  { batch-id: uint }
  { current-holder: principal, last-transfer: uint }
)

(define-map authorized-parties principal bool)
(define-map party-locations
  { party: principal }
  { location: (string-ascii 100), facility-type: (string-ascii 50) }
)

;; Authorization Functions
(define-public (add-authorized-party (party principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-parties party true))
  )
)

(define-public (register-party-location
  (party principal)
  (location (string-ascii 100))
  (facility-type (string-ascii 50))
)
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) (is-eq tx-sender party)) ERR-NOT-AUTHORIZED)
    (ok (map-set party-locations
      { party: party }
      { location: location, facility-type: facility-type }
    ))
  )
)

;; Custody Transfer Management
(define-public (initiate-custody-transfer
  (batch-id uint)
  (to-party principal)
  (location (string-ascii 100))
  (transport-method (string-ascii 50))
  (condition-notes (string-ascii 200))
)
  (let
    (
      (transfer-id (var-get next-transfer-id))
      (current-holder (map-get? current-custody { batch-id: batch-id }))
      (is-authorized (default-to false (map-get? authorized-parties tx-sender)))
      (to-party-authorized (default-to false (map-get? authorized-parties to-party)))
    )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! to-party-authorized ERR-NOT-AUTHORIZED)

    ;; Verify current custody
    (match current-holder
      holder-data (asserts! (is-eq tx-sender (get current-holder holder-data)) ERR-INVALID-CUSTODY)
      ;; If no current holder, this is the first transfer (from harvester)
      (asserts! true ERR-INVALID-CUSTODY)
    )

    ;; Create transfer record
    (map-set custody-transfers
      { transfer-id: transfer-id }
      {
        batch-id: batch-id,
        from-party: tx-sender,
        to-party: to-party,
        transfer-date: block-height,
        location: location,
        transport-method: transport-method,
        condition-notes: condition-notes,
        verified: false,
        verifier: none
      }
    )

    ;; Update current custody
    (map-set current-custody
      { batch-id: batch-id }
      { current-holder: to-party, last-transfer: transfer-id }
    )

    (var-set next-transfer-id (+ transfer-id u1))
    (ok transfer-id)
  )
)

(define-public (verify-custody-transfer
  (transfer-id uint)
  (verification-notes (string-ascii 200))
)
  (let
    (
      (transfer-data (unwrap! (map-get? custody-transfers { transfer-id: transfer-id }) ERR-TRANSFER-NOT-FOUND))
      (is-authorized (default-to false (map-get? authorized-parties tx-sender)))
    )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) is-authorized) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq tx-sender (get from-party transfer-data))) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq tx-sender (get to-party transfer-data))) ERR-NOT-AUTHORIZED)

    (ok (map-set custody-transfers
      { transfer-id: transfer-id }
      (merge transfer-data {
        verified: true,
        verifier: (some tx-sender)
      })
    ))
  )
)

(define-public (record-processing-step
  (batch-id uint)
  (processing-type (string-ascii 50))
  (location (string-ascii 100))
  (notes (string-ascii 200))
)
  (let
    (
      (transfer-id (var-get next-transfer-id))
      (current-holder (unwrap! (map-get? current-custody { batch-id: batch-id }) ERR-BATCH-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get current-holder current-holder)) ERR-NOT-AUTHORIZED)

    ;; Record processing as internal transfer
    (map-set custody-transfers
      { transfer-id: transfer-id }
      {
        batch-id: batch-id,
        from-party: tx-sender,
        to-party: tx-sender,
        transfer-date: block-height,
        location: location,
        transport-method: processing-type,
        condition-notes: notes,
        verified: true,
        verifier: (some tx-sender)
      }
    )

    (var-set next-transfer-id (+ transfer-id u1))
    (ok transfer-id)
  )
)

;; Read-only Functions
(define-read-only (get-custody-transfer (transfer-id uint))
  (map-get? custody-transfers { transfer-id: transfer-id })
)

(define-read-only (get-current-custody (batch-id uint))
  (map-get? current-custody { batch-id: batch-id })
)

(define-read-only (get-custody-history (batch-id uint))
  ;; This would require iteration in a real implementation
  ;; For now, returns the current custody info
  (map-get? current-custody { batch-id: batch-id })
)

(define-read-only (is-party-authorized (party principal))
  (default-to false (map-get? authorized-parties party))
)

(define-read-only (get-party-location (party principal))
  (map-get? party-locations { party: party })
)

(define-read-only (get-total-transfers)
  (- (var-get next-transfer-id) u1)
)
