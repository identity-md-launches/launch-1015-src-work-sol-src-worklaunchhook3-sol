# Work test suite

Run `forge build` and `forge test`. All dependencies are already vendored. No RPC,
network, FFI, environment mutation, or additional configuration is required.

The shared fixture deploys the vendored Uniswap v4 PoolManager and the actual Work
and WorkLaunchHook3 contracts. The hook constructor runs at a mined CREATE2 address
with exactly the required 0x2044 flags. Only the external IMD token is modeled
locally at its specified address; the PoolManager is never replaced by a mock.

## Coverage

- Existing initialization, constructor, callback authentication, treasury bounds,
  fee schedule, swap, partial-fill, failed settlement, sweep, and reentrancy tests
  are retained. Failed initialization and pre-initialization swaps must leave the
  launch usable. Empty liquidity creates no fees. One-unit swaps exercise all four
  direction/mode combinations.
- Real PoolManager swap events provide pre-hook amounts; actual trader transfers
  provide post-hook amounts. Fee tests check both currencies, exact input/output,
  gross-up, rounding, launch timing, and standing-fee changes. Repeated swap round
  trips cannot create tokens. Each fuzz test runs 1,000 cases through inline config.
- Work edge tests cover zero, one unit, full supply, self transfers, invalid zero
  recipients, maximum values, unlimited allowance, replacement, revocation, and
  atomic rollback of allowance spending on a failed transfer.

## Stateful properties

`WorkLaunchInvariant.t.sol` runs 256 sequences of 96 calls to
`WorkLaunchHandler`, with unexpected reverts treated as failures. Three funded
actors swap, donate, sweep, attempt sweeps inside an unlock, advance time, change
fees, attempt unauthorized changes and reinitialization, and transfer/approve/spend
WORK. Explicit target selectors keep the fuzzer on those actions. Setup seeds
nonzero obligations in both currencies through all four swap modes.

The invariants assert:

1. Cumulative fees plus donations equal outstanding claims plus direct hook
   balances plus treasury receipts, separately for each currency. Ghost fees use
   AMM events and trader transfers, independently of the claims being checked.
2. Claims are backed by PoolManager token balances; the sum of tracked holder
   balances and each fixed total supply stay at 1,000,000,000 tokens.
3. Launch time never changes, only authorized fee settings persist, and the fee
   stays within its time-dependent bounds.
4. WORK allowances equal approvals less authorized spending, with unlimited
   approvals preserved. Every randomized sequence ends with a normal sweep that
   must deliver all remaining obligations.

Transfer-false, transfer-revert, and no-return IMD modes are exercised during
random sweeps, then restored so later trades can execute. The deterministic
handler test exercises every action and recovery from multiple failures.

## Reported limitation

The independent sweep guarantee fails if IMD's direct-balance query reverts or
its direct transfer returns malformed data: the unguarded query/decode aborts
WORK's leg too. This is reported in `.imd-findings.json` with a self-contained
Foundry proof that was run and failed on both inputs. The earlier test expecting
a whole-sweep revert was removed. The failing proof is embedded in the report,
not included as a failing submitted test or weakened into a passing assertion.

These IMD faults are local models, not claims about its current deployed code.
Live IMD behavior and deployed PoolManager integration remain unverified by this
offline suite; a live-state fork run would be separate validation.
