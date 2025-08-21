;; ======================================================================
;; Contract: StackAudit
;; Purpose : On-chain DAO-style auditing of org financial reports.
;;           - Orgs post reports (content-hash + period).
;;           - Auditors stake STX to challenge reports within a window.
;;           - DAO council votes to resolve disputes (quorum + support).
;;           - Automatic payouts / slashing and reputation updates.
;;           - Pausability & operator role for safe ops.
;; Author  : You + ChatGPT
;; License : MIT
;; ======================================================================

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Errors
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-constant ERR-UNAUTHORIZED     (err u100))
(define-constant ERR-PAUSED           (err u101))
(define-constant ERR-BAD-AMOUNT       (err u102))
(define-constant ERR-NOT-FOUND        (err u103))
(define-constant ERR-NOT-ORG          (err u104))
(define-constant ERR-NOT-AUDITOR      (err u105))
(define-constant ERR-WINDOW-CLOSED    (err u106))
(define-constant ERR-ALREADY-CHALLENGED (err u107))
(define-constant ERR-DUPLICATE        (err u108))
(define-constant ERR-ALREADY-FINAL    (err u109))
(define-constant ERR-VOTE-ENDED       (err u110))
(define-constant ERR-ALREADY-VOTED    (err u111))
(define-constant ERR-NO-STAKE         (err u112))
(define-constant ERR-RESOLUTION-EARLY (err u113))
(define-constant ERR-BAD-PARAMS       (err u114))
(define-constant ERR-NOT-COUNCIL      (err u115))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Roles, Admin, Pause
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-data-var admin principal tx-sender)
(define-map operators principal bool)
(define-data-var paused bool false)

(define-private (only-admin) 
  (begin 
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (ok true)))
(define-private (only-op-or-admin)
  (begin 
    (asserts! (or (is-eq tx-sender (var-get admin)) (default-to false (map-get? operators tx-sender))) ERR-UNAUTHORIZED)
    (ok true)))
(define-private (when-active) 
  (begin
    (asserts! (not (var-get paused)) ERR-PAUSED)
    (ok true)))

(define-public (set-operator (who principal) (flag bool))
  (begin 
    (try! (only-admin))
    (asserts! (is-some (some who)) ERR-BAD-PARAMS)
    (ok (map-set operators who flag))))

(define-public (set-paused (p bool))
  (begin 
    (try! (only-op-or-admin))
    (var-set paused p) 
    (ok p)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Council / Governance Parameters
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; DAO council addresses who vote on challenges
(define-map council principal bool)
(define-data-var council-size uint u0)

(define-public (add-council (who principal))
  (begin
    (try! (only-op-or-admin))
    (asserts! (not (default-to false (map-get? council who))) ERR-DUPLICATE)
    (map-set council who true)
    (var-set council-size (+ (var-get council-size) u1))
    (ok true)))

(define-public (remove-council (who principal))
  (begin
    (try! (only-op-or-admin))
    (asserts! (default-to false (map-get? council who)) ERR-NOT-COUNCIL)
    (map-delete council who)
    (var-set council-size (- (var-get council-size) u1))
    (ok true)))

(define-read-only (is-council? (who principal))
  (default-to false (map-get? council who)))

;; Voting rules (configurable)
(define-data-var voting-window uint u100)      ;; blocks to vote
(define-data-var min-quorum    uint u2)        ;; minimum number of council votes
(define-data-var min-support   uint u60)       ;; % yes of votes cast required (0..100)
(define-public (set-governance-params (window uint) (quorum uint) (support uint))
  (begin
    (try! (only-op-or-admin))
    (asserts! (and (> window u0) (> quorum u0) (and (>= support u0) (<= support u100))) ERR-BAD-PARAMS)
    (var-set voting-window window)
    (var-set min-quorum quorum)
    (var-set min-support support)
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Economic Parameters
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-data-var org-min-bond       uint u1000000)  ;; 1 STX in microstx for example
(define-data-var audit-min-stake    uint u500000)   ;; 0.5 STX
(define-data-var challenge-window   uint u150)      ;; blocks after report posting
(define-data-var resolver-reward-bps uint u500)     ;; 5% to challenger if correct, from org bond/stake
(define-data-var slashing-bps        uint u1000)    ;; 10% slash on losing side (basis points 1/100 of %)

(define-public (set-economic-params (org-bond uint) (aud-stake uint) (chall-win uint) (reward-bps uint) (slash-bps uint))
  (begin
    (try! (only-op-or-admin))
    (asserts! (and (> org-bond u0) (> aud-stake u0) (> chall-win u0) (<= reward-bps u10000) (<= slash-bps u10000)) ERR-BAD-PARAMS)
    (var-set org-min-bond org-bond)
    (var-set audit-min-stake aud-stake)
    (var-set challenge-window chall-win)
    (var-set resolver-reward-bps reward-bps)
    (var-set slashing-bps slash-bps)
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Storage
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Orgs and their bond
(define-map orgs
  principal
  {
    bonded: uint,        ;; stx held in contract as org bond
    active: bool,
    reputation: uint     ;; increases on clean passes, decreases on failed reports
  })

;; Reports
(define-data-var next-report-id uint u1)
(define-map reports
  uint
  {
    org: principal,
    period-start: uint,
    period-end: uint,
    posted-height: uint,
    content-hash: (buff 32),   ;; e.g., IPFS CID hash
    status: uint               ;; 0=submitted, 1=finalized, 2=rejected
  })

;; Challenges per report (one at a time for simplicity)
(define-map challenges
  uint
  {
    challenger: principal,
    stake: uint,
    opened-height: uint,
    evidence-hash: (optional (buff 32)),
    yes-votes: uint,
    no-votes: uint,
    ended: bool,
    resolved: bool,
    winner: (optional principal)  ;; some(challenger) or some(org) or none (if unresolved)
  })

;; To prevent double votes: (report-id, voter) -> bool
(define-map challenge-votes
  { report-id: uint, voter: principal } bool)

;; Auditor reputation
(define-map auditor-rep principal uint)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utility
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-private (pay (to principal) (amt uint))
  (if (> amt u0)
      (stx-transfer? amt (as-contract tx-sender) to)
      (ok true)))

(define-private (collect (from principal) (amt uint))
  (if (> amt u0)
      (stx-transfer? amt from (as-contract tx-sender))
      (ok true)))

(define-private (only-org (p principal))
  (let ((o (map-get? orgs p)))
    (match o
      data (if (get active data) 
             (ok true)
             ERR-NOT-ORG)
      ERR-NOT-ORG)))

(define-private (only-council)
  (begin
    (asserts! (default-to false (map-get? council tx-sender)) ERR-NOT-COUNCIL)
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Org Lifecycle
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (register-org (bond uint))
  (begin
    (try! (when-active))
    (asserts! (>= bond (var-get org-min-bond)) ERR-BAD-AMOUNT)
    (asserts! (is-none (map-get? orgs tx-sender)) ERR-DUPLICATE)
    (try! (collect tx-sender bond))
    (map-set orgs tx-sender { bonded: bond, active: true, reputation: u0 })
    (ok true)))

(define-public (top-up-bond (amount uint))
  (begin
    (try! (when-active))
    (try! (only-org tx-sender))
    (asserts! (> amount u0) ERR-BAD-AMOUNT)
    (try! (collect tx-sender amount))
    (let ((o (unwrap! (map-get? orgs tx-sender) ERR-NOT-FOUND)))
      (map-set orgs tx-sender (merge o { bonded: (+ (get bonded o) amount) })))
    (ok true)))

(define-public (deactivate-org)
  (begin
    (try! (only-op-or-admin))
    (let ((o (map-get? orgs tx-sender)))
      (match o
        data (begin (map-set orgs tx-sender (merge data { active: false })) (ok true))
        ERR-NOT-FOUND))))

(define-public (withdraw-bond (amount uint))
  (begin
    (try! (when-active))
    (try! (only-org tx-sender))
    (let ((o (unwrap! (map-get? orgs tx-sender) ERR-NOT-FOUND)))
      (asserts! (<= amount (get bonded o)) ERR-BAD-AMOUNT)
      ;; NOTE: In production, ensure no active challenges against this org's reports.
      (map-set orgs tx-sender (merge o { bonded: (- (get bonded o) amount) }))
      (try! (pay tx-sender amount))
      (ok true))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reporting
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (submit-report (period-start uint) (period-end uint) (hash (buff 32)))
  (begin
    (try! (when-active))
    (try! (only-org tx-sender))
    (asserts! (< period-start period-end) ERR-BAD-PARAMS)
    (let ((rid (var-get next-report-id)))
      (begin
        (asserts! (is-some (some hash)) ERR-BAD-PARAMS)
        (let ((report-data {
          org: tx-sender,
          period-start: period-start,
          period-end: period-end,
          posted-height: stacks-block-height,
          content-hash: hash,
          status: u0   ;; submitted
        }))
          (map-set reports rid report-data)
          (var-set next-report-id (+ rid u1))
          (ok rid))))))

(define-read-only (get-report (report-id uint))
  (map-get? reports report-id))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Challenge Flow (Auditor staking + dispute + council voting)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (open-challenge (report-id uint) (stake uint) (evidence (optional (buff 32))))
  (begin
    (try! (when-active))
    (asserts! (>= stake (var-get audit-min-stake)) ERR-BAD-AMOUNT)
    (let ((r (map-get? reports report-id)))
      (match r
        rep
          (begin
            (asserts! (is-eq (get status rep) u0) ERR-ALREADY-FINAL)
            (asserts! (<= (- stacks-block-height (get posted-height rep)) (var-get challenge-window)) ERR-WINDOW-CLOSED)
            (asserts! (is-none (map-get? challenges report-id)) ERR-ALREADY-CHALLENGED)
            ;; collect stake
            (try! (collect tx-sender stake))
            (let ((evidence-opt (match evidence
                                     ev (some ev)
                                     none))
                  (challenge-data {
                    challenger: tx-sender,
                    stake: stake,
                    opened-height: stacks-block-height,
                    evidence-hash: evidence-opt,
                    yes-votes: u0,
                    no-votes: u0,
                    ended: false,
                    resolved: false,
                    winner: none
                  }))
              (map-set challenges report-id challenge-data))
            ;; tag auditor rep presence
            (map-set auditor-rep tx-sender (default-to u0 (map-get? auditor-rep tx-sender)))
            (ok true))
        ERR-NOT-FOUND))))

(define-public (vote-challenge (report-id uint) (support bool))
  (let ((report (unwrap! (map-get? reports report-id) ERR-NOT-FOUND))
        (challenge (unwrap! (map-get? challenges report-id) ERR-NOT-FOUND)))
    (begin
      (try! (when-active))
      (try! (only-council))
      (asserts! (not (get ended challenge)) ERR-VOTE-ENDED)
      (let ((elapsed (- stacks-block-height (get opened-height challenge))))
        (asserts! (<= elapsed (var-get voting-window)) ERR-VOTE-ENDED))
      (asserts! (not (default-to false (map-get? challenge-votes {report-id: report-id, voter: tx-sender}))) ERR-ALREADY-VOTED)
      (let ((votes-updated (map-set challenge-votes {report-id: report-id, voter: tx-sender} true))
            (updated-challenge (merge challenge { 
              yes-votes: (if support (+ (get yes-votes challenge) u1) (get yes-votes challenge)),
              no-votes: (if support (get no-votes challenge) (+ (get no-votes challenge) u1))
            })))
        (ok (map-set challenges report-id updated-challenge))))))

(define-public (end-voting (report-id uint))
  (begin
    (try! (when-active))
    (let ((c (map-get? challenges report-id)))
      (match c
        chal
          (let ((elapsed (- stacks-block-height (get opened-height chal))))
            (asserts! (> elapsed (var-get voting-window)) ERR-RESOLUTION-EARLY)
            (let ((updated-challenge (merge chal { ended: true })))
              (ok (map-set challenges report-id updated-challenge))))
        ERR-NOT-FOUND))))

;; Resolve challenge -> distribute rewards/slashing and set report status
(define-public (resolve-challenge (report-id uint))
  (let ((report (unwrap! (map-get? reports report-id) ERR-NOT-FOUND))
        (challenge (unwrap! (map-get? challenges report-id) ERR-NOT-FOUND)))
    (begin
      (try! (when-active))
      (asserts! (get ended challenge) ERR-RESOLUTION-EARLY)
      (asserts! (not (get resolved challenge)) ERR-DUPLICATE)

      (let (
            (yes (get yes-votes challenge))
            (no  (get no-votes challenge))
            (total (+ yes no))
            (quorum (var-get min-quorum))
            (support (if (> total u0) (/ (* yes u100) total) u0))
           )
        ;; Check quorum & support
        (if (and (>= total quorum) (>= support (var-get min-support)))
            ;; Challenge passes -> report rejected, challenger wins
            (resolve-win-challenger report-id report challenge)
            ;; Challenge fails -> report finalized, org wins
            (resolve-win-org report-id report challenge))))))

(define-private (resolve-win-challenger (report-id uint) (rep {org: principal, period-start: uint, period-end: uint, posted-height: uint, content-hash: (buff 32), status: uint}) (chal {challenger: principal, stake: uint, opened-height: uint, evidence-hash: (optional (buff 32)), yes-votes: uint, no-votes: uint, ended: bool, resolved: bool, winner: (optional principal)}))
  (let (
        (org (get org rep))
        (org-state (unwrap! (map-get? orgs (get org rep)) ERR-NOT-FOUND))
        (reward-bps (var-get resolver-reward-bps))
        (slash-bps  (var-get slashing-bps))
        (stake (get stake chal))
        (slash-amt (/ (* stake slash-bps) u10000)) ;; losing side slash baseline (here, org wins/loses decided outside)
        (bonus (/ (* (get bonded org-state) reward-bps) u10000))
       )
    ;; Update report status to rejected
    (map-set reports report-id (merge rep { status: u2 }))
    ;; Pay challenger: their stake + bonus from org bond; org slashed by bonus
    (let ((new-org-bond (if (>= (get bonded org-state) bonus) (- (get bonded org-state) bonus) u0)))
      (map-set orgs (get org rep) (merge org-state { bonded: new-org-bond, reputation: (if (> (get reputation org-state) u0) (- (get reputation org-state) u1) u0) }))
      (try! (pay (get challenger chal) (+ stake bonus))))
    ;; Mark challenge resolved
    (map-set challenges report-id (merge chal { resolved: true, winner: (some (get challenger chal)) }))
    ;; Auditor rep up
    (map-set auditor-rep (get challenger chal) (+ (default-to u0 (map-get? auditor-rep (get challenger chal))) u1))
    (ok true)))

(define-private (resolve-win-org (report-id uint) (rep {org: principal, period-start: uint, period-end: uint, posted-height: uint, content-hash: (buff 32), status: uint}) (chal {challenger: principal, stake: uint, opened-height: uint, evidence-hash: (optional (buff 32)), yes-votes: uint, no-votes: uint, ended: bool, resolved: bool, winner: (optional principal)}))
  (let (
        (org (get org rep))
        (org-state (unwrap! (map-get? orgs (get org rep)) ERR-NOT-FOUND))
        (slash-bps  (var-get slashing-bps))
        (stake (get stake chal))
        (slash-amt (/ (* stake slash-bps) u10000))
       )
    ;; Report finalized
    (map-set reports report-id (merge rep { status: u1 }))
    ;; Slash challenger stake -> pay to org; return remainder to challenger
    (let ((to-org slash-amt)
          (back (- stake slash-amt)))
      (try! (pay (get org rep) to-org))
      (try! (pay (get challenger chal) back)))
    ;; Buff org reputation
    (map-set orgs (get org rep) (merge org-state { reputation: (+ (get reputation org-state) u1) }))
    ;; Mark challenge resolved
    (map-set challenges report-id (merge chal { resolved: true, winner: (some (get org rep)) }))
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Read-only Views
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-read-only (get-params)
  {
    admin: (var-get admin),
    paused: (var-get paused),
    council-size: (var-get council-size),
    voting-window: (var-get voting-window),
    min-quorum: (var-get min-quorum),
    min-support: (var-get min-support),
    org-min-bond: (var-get org-min-bond),
    audit-min-stake: (var-get audit-min-stake),
    challenge-window: (var-get challenge-window),
    resolver-reward-bps: (var-get resolver-reward-bps),
    slashing-bps: (var-get slashing-bps)
  })

(define-read-only (get-org (p principal))
  (map-get? orgs p))

(define-read-only (get-auditor-rep (p principal))
  (default-to u0 (map-get? auditor-rep p)))

(define-read-only (get-challenge (report-id uint))
  (map-get? challenges report-id))

(define-read-only (has-voted? (report-id uint) (voter principal))
  (default-to false (map-get? challenge-votes {report-id: report-id, voter: voter})))
