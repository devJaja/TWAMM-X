// Generate a real Groth16 proof for TWAMM-X test inputs
// Run: node gen_proof.js
const snarkjs = require("snarkjs");
const { buildPoseidon } = require("circomlibjs");
const fs = require("fs");
const path = require("path");

async function main() {
    const poseidon = await buildPoseidon();
    const F = poseidon.F;

    // Test inputs matching test_revealOrder in TWAMMXHookTest
    // owner = address(this) in test = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496
    const owner      = BigInt("0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496");
    const amountIn   = BigInt("200000000000000000000"); // 200e18
    const zeroForOne = BigInt(1);
    const salt       = BigInt("0x" + Buffer.from("mysalt").toString("hex").padEnd(64, "0"));
    const expiry     = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1hr from now
    // poolId — use a placeholder (not constrained by circuit)
    const poolIdHash = BigInt("0x9fc76316cd12544f7b090313d08f5aa2ab5be850bda5c879481e09e17dd5afd8");

    // Compute Poseidon(owner, amountIn, zeroForOne, salt)
    const hashOut = poseidon([owner, amountIn, zeroForOne, salt]);
    const commitmentHash = F.toObject(hashOut);

    console.log("owner:          ", owner.toString());
    console.log("amountIn:       ", amountIn.toString());
    console.log("zeroForOne:     ", zeroForOne.toString());
    console.log("salt:           ", salt.toString());
    console.log("commitmentHash: ", commitmentHash.toString());
    console.log("poolIdHash:     ", poolIdHash.toString());
    console.log("expiry:         ", expiry.toString());

    const input = {
        owner:          owner.toString(),
        amountIn:       amountIn.toString(),
        zeroForOne:     zeroForOne.toString(),
        salt:           salt.toString(),
        commitmentHash: commitmentHash.toString(),
        poolIdHash:     poolIdHash.toString(),
        expiry:         expiry.toString()
    };

    fs.writeFileSync("input.json", JSON.stringify(input, null, 2));
    console.log("\nWrote input.json");

    // Generate witness (file-based)
    await snarkjs.wtns.calculate(
        input,
        path.join(__dirname, "order_commit_js/order_commit.wasm"),
        "witness.wtns"
    );

    // Generate proof
    const { proof, publicSignals } = await snarkjs.groth16.prove(
        path.join(__dirname, "order_commit_final.zkey"),
        "witness.wtns"
    );

    // Verify locally
    const vKey = JSON.parse(fs.readFileSync("verification_key.json"));
    const valid = await snarkjs.groth16.verify(vKey, publicSignals, proof);
    console.log("\nProof valid:", valid);

    // Export Solidity calldata
    const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
    console.log("\nSolidity calldata:\n", calldata);

    // Save proof and public signals
    fs.writeFileSync("proof.json", JSON.stringify(proof, null, 2));
    fs.writeFileSync("public.json", JSON.stringify(publicSignals, null, 2));

    // Parse calldata for use in Foundry tests
    // calldata format: [pA[0],pA[1]],[[pB[0][0],pB[0][1]],[pB[1][0],pB[1][1]]],[pC[0],pC[1]],[pub0,pub1,pub2]
    const parsed = JSON.parse("[" + calldata + "]");
    const testProof = {
        pA: parsed[0],
        pB: parsed[1],
        pC: parsed[2],
        pubSignals: parsed[3],
        commitmentHash: commitmentHash.toString(),
        owner: owner.toString(),
        amountIn: amountIn.toString(),
        salt: salt.toString(),
        expiry: expiry.toString()
    };
    fs.writeFileSync("test_proof.json", JSON.stringify(testProof, null, 2));
    console.log("\nWrote test_proof.json — use these values in Foundry tests");
}

main().catch(console.error);
