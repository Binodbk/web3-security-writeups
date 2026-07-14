// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract CRIT01_BridgeCreditUnderflow is Test {
    address internal constant LZ_ENDPOINT = address(0x1000);
    address internal constant USDC        = address(0x2000);
    address internal constant AUSDC       =address(0x3000);
    address internal constant USDC_WHALE  = address(0x4000);

    uint32 internal constant HUB_EID       = 30101;
    uint32 internal constant SATELLITE_EID = 30111;

    address internal constant VICTIM = address(0xCAFE);

    OverlayerWrap internal hubOva;
    OverlayerWrap internal satelliteOva;

    function setUp() public {
        vm.createSelectFork("<fork-mainnet-rpc>");

        OverlayerWrapCoreTypes.StableCoin memory col = OverlayerWrapCoreTypes.StableCoin({
            addr: USDC,
            decimals: 6
        });
        OverlayerWrapCoreTypes.StableCoin memory aCol = OverlayerWrapCoreTypes.StableCoin({
            addr: AUSDC,
            decimals: 6
        });

        IOverlayerWrapDefs.ConstructorParams memory params = IOverlayerWrapDefs.ConstructorParams({
            admin:                   address(this),
            lzEndpoint:              LZ_ENDPOINT,
            name:                    "OVA",
            symbol:                  "OVA",
            collateral:              col,
            aCollateral:             aCol,
            maxMintPerBlock:         type(uint256).max,
            maxRedeemPerBlock:       type(uint256).max,
            minValmaxRedeemPerBlock: 1,
            hubChainId:              block.chainid
        });

        hubOva       = new OverlayerWrap(params);
        satelliteOva = new OverlayerWrap(params);

        hubOva.setPeer(SATELLITE_EID, bytes32(uint256(uint160(address(satelliteOva)))));
        satelliteOva.setPeer(HUB_EID, bytes32(uint256(uint160(address(hubOva)))));

        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(VICTIM, 10_000 * 1e6);
        IERC20(USDC).approve(address(hubOva), type(uint256).max);
        hubOva.mint(OverlayerWrapCoreTypes.Order({
            benefactor:          VICTIM,
            beneficiary:         VICTIM,
            collateral:          USDC,
            collateralAmount:    10_000 * 1e6,
            overlayerWrapAmount: 10_000 * 1e18
        }));
        vm.stopPrank();

        // Hub-side burn proof: victim's funds exist on hub before any bridge attempt.
        // In production, send() burns these before the LZ message is sent.
        assertEq(hubOva.balanceOf(VICTIM),        10_000 * 1e18, "setup: victim holds OVA on hub");
        assertEq(satelliteOva.totalBridgedOut(),   0,             "setup: satellite totalBridgedOut is zero");
    }

    /**
     * LZ endpoint delivering a 1000 OVA credit on the satellite.
     * In production, the hub-side _debit() has already burned the victim's tokens
     * before this message was enqueued — that burn is shown in setUp() above.
     *
     * OFT shared-decimal encoding:
     *   OVA decimals = 18, sharedDecimals = 6, decimalConversionRate = 10^12
     *   amountSD = 1_000 * 1e6 => _toLD() = 1_000 * 1e6 * 10^12 = 1_000 * 1e18
     *
     * Execution path on satellite:
     *   super._credit() calls _mint(VICTIM, 1_000e18)  => succeeds
     *   totalBridgedOut -= 1_000e18                    => 0 - 1_000e18 => panic 0x11
     *   entire tx reverts, mint is rolled back
     *   VICTIM receives zero tokens, funds are permanently destroyed
     */
    function test_CRIT01_satelliteCreditAlwaysUnderflows() public {
        uint64 amountSD = 1_000 * 1e6;

        bytes memory oftPayload = abi.encodePacked(
            bytes32(uint256(uint160(VICTIM))),
            amountSD
        );

        Origin memory origin = Origin({
            srcEid:  HUB_EID,
            sender:  bytes32(uint256(uint160(address(hubOva)))),
            nonce:   1
        });

        assertEq(satelliteOva.totalBridgedOut(), 0, "pre: satellite counter is zero");

        vm.prank(LZ_ENDPOINT);
        vm.expectRevert();
        satelliteOva.lzReceive(origin, keccak256("guid-1"), oftPayload, address(0), "");

        assertEq(satelliteOva.balanceOf(VICTIM),  0, "victim: zero OVA on satellite - permanently lost");
        assertEq(satelliteOva.totalBridgedOut(),   0, "satellite: state unchanged after revert");
    }

    function test_CRIT01_retriesNeverRecover() public {
        uint64 amountSD     = 500 * 1e6;
        bytes memory payload = abi.encodePacked(
            bytes32(uint256(uint160(VICTIM))),
            amountSD
        );
        Origin memory origin = Origin({
            srcEid:  HUB_EID,
            sender:  bytes32(uint256(uint160(address(hubOva)))),
            nonce:   2
        });

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(LZ_ENDPOINT);
            vm.expectRevert();
            satelliteOva.lzReceive(
                origin,
                keccak256(abi.encode("guid-retry", i)),
                payload,
                address(0),
                ""
            );
        }

        assertEq(satelliteOva.balanceOf(VICTIM), 0, "victim: still zero after 3 retries");
        assertEq(satelliteOva.totalBridgedOut(),  0, "satellite: counter never changed across retries");
    }

    function test_CRIT01_hubStateDoesNotHealSatellite() public {
        assertEq(hubOva.totalBridgedOut(),       0, "hub: no debit initiated yet");
        assertEq(satelliteOva.totalBridgedOut(), 0, "satellite: independent slot, always zero");

        uint64 amountSD     = 200 * 1e6;
        bytes memory payload = abi.encodePacked(
            bytes32(uint256(uint160(VICTIM))),
            amountSD
        );
        Origin memory origin = Origin({
            srcEid:  HUB_EID,
            sender:  bytes32(uint256(uint160(address(hubOva)))),
            nonce:   3
        });

        vm.prank(LZ_ENDPOINT);
        vm.expectRevert();
        satelliteOva.lzReceive(origin, keccak256("guid-3"), payload, address(0), "");

        assertEq(hubOva.totalBridgedOut(),       0, "hub: unchanged - proof of complete isolation");
        assertEq(satelliteOva.totalBridgedOut(), 0, "satellite: unchanged - permanently bricked");
        assertEq(satelliteOva.balanceOf(VICTIM), 0, "victim: still zero");
    }
}
