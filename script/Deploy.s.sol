// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BountyEscrow} from "../src/BountyEscrow.sol";

/// Deploy BountyEscrow. NOT used in Phase 0 (local tests only) — this is ready
/// for when you take it to Sepolia. Run with:
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC --broadcast --private-key $PK
contract Deploy is Script {
    function run() external {
        // resolver defaults to the deployer; change to a dedicated resolver key later.
        address resolver = vm.envOr("RESOLVER", msg.sender);

        vm.startBroadcast();
        BountyEscrow escrow = new BountyEscrow(resolver);
        vm.stopBroadcast();

        console.log("BountyEscrow deployed at:", address(escrow));
        console.log("Resolver set to:", resolver);
    }
}
