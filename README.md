# Work / WORK

This Foundry project preserves the requested `Work.sol`, `WorkLaunchHook3.sol`,
and `launch.json` content (Solidity formatting only). The manifest's notes string
is unchanged, including its shorter `WorkLaunchHook` spelling; the deployable
contract is **WorkLaunchHook3**.

`Work` is an OpenZeppelin ERC-20 with 18 decimals. Its constructor mints exactly
1,000,000,000 WORK (10^27 base units) to its caller. It has no owner, subsequent
minting, pause, transfer tax, or upgrade entrypoint. When a factory deploys it,
the factory receives the entire supply and is responsible for distributing it
and providing launch liquidity.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Use Foundry with Solidity **0.8.26** available locally. The configuration pins
Cancun, optimizer enabled with 200 runs, via-IR, and `bytecode_hash = "none"`.
All Solidity dependencies are ordinary files under `lib/`; no dependency
installation or network connection is needed to build or test once the pinned
compiler is installed. No FFI, filesystem cheatcode permissions, RPC fork, test
environment variables, or keys are required.

Dependency revisions, archive checksums, and licenses are recorded in
[DEPENDENCIES.md](DEPENDENCIES.md). Vendored upstream sources are unchanged.

The tests deploy the actual Uniswap v4.0.0 PoolManager, deploy WORK normally, mine
and deploy the hook with CREATE2, initialize the pool, add funded liquidity, and
settle trades through a test-only router. A controllable test ERC-20 is installed
at the specified IMD address inside the isolated test EVM. This tests accounting
and failure handling; it does not verify the production IMD contract.

Coverage includes supply and ERC-20 transfers; actual CREATE2 permission bits;
both currency sort orders; initialization and callback access failures; admin
limits; ramp boundaries; exact input/output in both directions; partial fills;
rounding; fuzzed fees, amounts and times; failed swap settlement rollback; claim
redemption and direct donations; independent sweep failures and retries; nested
manager unlock failure; reentrant token callbacks; non-returning tokens; and
malformed return-data behavior.
Fee tests compare PoolManager's pre-hook Swap event with actual trader transfers
and the hook's ERC-6909 claim balances. Test contracts are not production routers.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Token | `Work`, no constructor arguments |
| Hook | `WorkLaunchHook3(IPoolManager m, address t)` |
| `m` | Deployment chain's real Uniswap v4 PoolManager; manifest `$poolManager` |
| `t` | Newly deployed WORK token; manifest `$token` |
| Paired currency (IMD) | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| Treasury and sole fee administrator | `0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0` |
| Pool LP fee | `12500` (1.25%, separate from hook fees) |
| Tick spacing | `60` |
| Initial sqrt price Q96 | `79228162514264337593543950336` (2^96) |
| Hook address mask | `uint160(address) & 0x3fff == 0x2044` |
| Enabled callbacks | `beforeInitialize`, `afterSwap`, `afterSwapReturnDelta` |

No chain or PoolManager address has been guessed. The deployment system resolves
the two manifest placeholders. Before launch, it must verify the manager's code,
the paired token's identity and behavior on that chain, and Cancun compatibility.
The Solidity/EVM artifacts are not a zkSync Era deployment package.

Sort currencies by ascending address in the PoolKey. Set `hooks` to the deployed
hook. The initial price is a ratio of **base units**, so equality of human token
amounts also depends on IMD decimals, which must be checked on the chosen chain.
The hook validates pair, fee, spacing, and hook address at initialization. It
records `openedAt` and rejects another initialization. It does not restrict the
initializer or validate the initial price itself: the launch factory must deploy
and initialize atomically at the manifest price to prevent a competing initializer
from choosing the opening price. Initialization should occur at a nonzero timestamp.

### CREATE2 salt

The constructor validates address flags; arbitrary CREATE/CREATE2 addresses will
revert. Mine against the actual factory, actual constructor arguments, and exact
compiled creation code. The preimage is:

```text
initCode = WorkLaunchHook3.creationCode ++ abi.encode(poolManager, token)
address = last20(keccak256(0xff ++ factory ++ salt ++ keccak256(initCode)))
address & 0x3fff must equal 0x2044
```

The read-only helper accepts all configuration as function arguments:

```sh
forge script script/MineWorkHook.s.sol:MineWorkHook \
  --sig 'run(address,address,address,uint256,uint256)' \
  <actual-create2-factory> <actual-pool-manager> <actual-work-token> 0 200000
```

Replace the angle-bracket arguments with deployment values. This searches a
bounded salt range and does not broadcast. If exhausted, retry the next range.
Check the predicted address is unoccupied on the target chain. The factory must
use the returned salt unchanged and exactly the same init code; factories that
transform salts need their own address calculation. Changing compiler settings,
bytecode, manager, token, or factory requires mining again. Tests exercise this
helper and compare its prediction to an actual CREATE2 deployment.

## Fees and operations

Rates are basis points, with denominator 10,000. Before initialization and at its
timestamp, `feeNow()` is 5000 (50%). With elapsed time `e` in seconds and current
standing fee `s`, the rate for `0 < e < 900` is:

```text
s + floor((5000 - s) * (900 - e) / 900)
```

At and after 900 seconds it is `s`, initially 200 (2%). With the default standing
fee, the midpoint is 26% and the rate at second 899 is 2.05%. Only the treasury
can call `setStandingFee(f)`, where `0 <= f <= 1000` (0–10%); `StandingFee(f)` is
emitted. Updates take effect immediately and also alter an ongoing ramp without
restarting its clock. There is no timelock, admin transfer, treasury replacement,
emergency withdrawal, pause, or upgrade power.

The fee is charged in the swap's **unspecified currency**:

| Swap mode | Fee currency | Hook claim | Trader result |
| --- | --- | --- | --- |
| Exact input | Output | `floor(grossOutput * r / 10000)` | Receives gross output less the fee |
| Exact output | Input | `floor(poolInput * r / (10000 - r))` | Pays pool input plus the fee |

For exact output, gross-up makes the fee the rate's share of total trader input,
subject to integer rounding. For exact input, the rate is a share of gross output
before the hook deduction. Either IMD or WORK can accrue, depending on direction
and mode. Fees use actual executed deltas, including partial fills. The LP fee is
already reflected in pool deltas. Routers must enforce slippage, maximum input,
minimum output and deadlines accounting for both fees and possible partial fills.
The snipe ramp does not guarantee protection from front-running or sandwiches.

The hook mints PoolManager ERC-6909 claims during a swap. It leaves the backing
tokens in the manager, so swaps do not rely on the treasury accepting an immediate
transfer and do not need a native ETH balance. Anyone can pay gas to call
`sweep()`. For IMD then WORK, the hook independently unlocks the manager, burns
its claim balance and takes the corresponding tokens directly to the treasury.
It also forwards any direct balances of those two tokens at the hook address.
There is no caller reward or native ETH leg and no conversion into ETH.

## After launch

- The factory/operator distributes the minted supply and funds liquidity.
- The treasury may call `setStandingFee(uint256)` to adjust the standing fee
  within 0–1000 basis points. No additional owner-set configuration is required.
- A keeper or any user calls `sweep()` periodically, monitors `SweepFailed(token)`
  and claim balances, and retries failed legs when transfer conditions recover.
  Claim redemption attempted while the manager is already unlocked is caught and
  can be retried after that operation completes.
- The deployer verifies deployed source, parameters, address flags, and the pool
  initialization transaction. Arrange independent adversarial review before release.

## Assumptions and supplied-code limitations

The manager must be the authentic, compatible PoolManager and the token argument
must be the deployed WORK contract. The exact constructor only rejects a zero or
IMD token address; it does not validate manager code or token code. Deployment
validation is the factory/operator's responsibility. The treasury address is fixed.

IMD must have truthful `balanceOf` accounting and standard, non-rebasing,
non-fee-on-transfer behavior compatible with v4. Normal transfer reverts or
`false` responses emit `SweepFailed`, preserve the failed claim/balance, and let
the other leg proceed. Empty transfer return data is supported. A reverting
`balanceOf` or malformed nonempty direct `transfer` return data can revert the
entire sweep, since these operations are outside its unlock try/catch. A regression
test records that limitation; the requested implementation has not been changed.

Unrelated tokens and forced ETH have no recovery path. Fee arithmetic uses signed
128-bit PoolManager deltas; the minimum int128 input cannot be negated and would
revert. Normal tested swaps are far below this boundary, as is WORK's fixed supply.
Time-dependent fees follow the target chain's `block.timestamp` semantics.

Local build/test results are not a security audit or verification of external
chain state. Forge's lint warnings on the supplied timestamp logic, casts, and
external calls are not suppressed. No on-chain transactions have been sent, and
Slither/Mythril or an independent security review have not been run here.
