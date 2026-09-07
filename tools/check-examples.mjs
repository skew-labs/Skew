import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const load = async (name) => JSON.parse(await readFile(new URL(`../examples/${name}`, import.meta.url), "utf8"));
const decimal = /^(0|[1-9][0-9]*)$/;
const digest = /^sha256:[0-9a-f]{64}$/;
const toInt = (value, label) => {
  assert.equal(typeof value, "string", `${label} must be a string`);
  assert.match(value, decimal, `${label} must be an unsigned decimal string`);
  return BigInt(value);
};

const [intent, contract, receipt] = await Promise.all([
  load("work-intent.json"),
  load("execution-contract.json"),
  load("acceptance-receipt.json"),
]);

assert.equal(intent.job_id, contract.job_id);
assert.equal(contract.job_id, receipt.job_id);
assert.equal(intent.maximum_budget.network, "eip155:8453");
assert.equal(contract.settlement_home, intent.maximum_budget.network);
assert.equal(receipt.settlement.network, contract.settlement_home);
assert.equal(contract.economics.payout_condition, "ACCEPTED_RESULT_ONLY");
assert.equal(receipt.status, "ACCEPTED");
assert.match(intent.input.digest, digest);
assert.match(intent.result.output_schema_digest, digest);
assert.match(receipt.accepted_output_digest, digest);
assert.match(receipt.economic_effect_id, digest);
assert.equal(intent.verification.required_replicas, String(receipt.replica_output_digests.length));
for (const output of receipt.replica_output_digests) assert.equal(output, receipt.accepted_output_digest);
assert.notEqual(contract.allocations[0].fault_domain, contract.allocations[1].fault_domain);

const reserved = toInt(contract.economics.reservation_amount_minor, "reservation");
const contractParts = ["worker_amount_minor", "verifier_amount_minor", "protocol_amount_minor", "refund_amount_minor"]
  .map((key) => toInt(contract.economics[key], `contract.${key}`));
assert.equal(contractParts.reduce((sum, value) => sum + value, 0n), reserved);
assert.ok(reserved <= toInt(intent.maximum_budget.amount_minor, "maximum budget"));

for (const key of ["worker_amount_minor", "verifier_amount_minor", "protocol_amount_minor", "refund_amount_minor"]) {
  assert.equal(receipt.settlement[key], contract.economics[key], `receipt changed ${key}`);
}
assert.equal(receipt.settlement.state, "READY_NOT_SUBMITTED");

console.log("Skew public example chain is internally consistent.");
