# StackAudit DAO Smart Contract

A decentralized financial report auditing system built on Stacks blockchain using Clarity smart contracts.

## Overview

StackAudit enables transparent on-chain verification of organizational financial reports through a DAO governance structure. Organizations stake STX to submit reports, while auditors can challenge suspicious submissions for rewards.

## Features

### Core Functionality
- 🏢 **Organization Management**
  - Bond-based registration
  - Report submission with content hash verification
  - Reputation scoring
  - Flexible bond management

- 🔍 **Audit System**
  - Challenge mechanism with STX staking
  - Evidence submission
  - Automated reward distribution
  - Reputation tracking

- 🏛️ **DAO Governance**
  - Council member management
  - Configurable voting parameters
  - Support threshold mechanisms
  - Time-bounded voting periods

### Economic Design
- Organization bond requirements
- Auditor stake minimums
- Challenge window configuration
- Reward/slash basis points
- Automated payment distribution

## Contract Interface

### Administrative Functions
```clarity
(set-operator (who principal) (flag bool))
(set-paused (p bool))
(add-council (who principal))
(remove-council (who principal))
```

### Organization Functions
```clarity
(register-org (bond uint))
(submit-report (period-start uint) (period-end uint) (hash (buff 32)))
(top-up-bond (amount uint))
(withdraw-bond (amount uint))
```

### Auditing Functions
```clarity
(open-challenge (report-id uint) (stake uint) (evidence (optional (buff 32))))
(vote-challenge (report-id uint) (support bool))
(end-voting (report-id uint))
(resolve-challenge (report-id uint))
```

## Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `org-min-bond` | Minimum organization bond | 1.0 STX |
| `audit-min-stake` | Minimum auditor stake | 0.5 STX |
| `challenge-window` | Blocks to challenge | 150 |
| `voting-window` | Blocks for voting | 100 |
| `min-quorum` | Minimum votes needed | 2 |
| `min-support` | Required yes vote % | 60% |

## Error Codes

| Code | Description |
|------|-------------|
| `u100` | Unauthorized |
| `u101` | Contract paused |
| `u102` | Invalid amount |
| `u103` | Entity not found |
| `u104` | Not an organization |
| `u105` | Not an auditor |

## Security Features

- Role-based access control
- Emergency pause functionality
- Double-vote prevention
- Time-bounded operations
- Safe arithmetic operations
- Minimum stake requirements

## Development Setup

1. Install Clarinet:
```bash
curl -sL https://install.clarinet.sh | sh
```

2. Initialize project:
```bash
clarinet new stack-audit && cd stack-audit
```

3. Run tests:
```bash
clarinet test
```

## Deployment

1. Configure networks in Clarinet.toml

2. Deploy to testnet:
```bash
clarinet deploy --network testnet
```

## Contributing

1. Fork the repository
2. Create feature branch
3. Commit changes
4. Push to branch
5. Open pull request

## Testing

Contract includes comprehensive tests for:
- Organization registration
- Report submission
- Challenge mechanics
- Voting process
- Reward distribution
- Access control

