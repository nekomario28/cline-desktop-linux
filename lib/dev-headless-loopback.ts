#!/usr/bin/env bun
// Adapted from Cline's apps/examples/desktop-app/scripts/dev-headless.ts.
// Keep the web UI on loopback; upstream `next dev` otherwise binds 0.0.0.0.
import { randomUUID } from "node:crypto";
import { createServer } from "node:net";

const desktopApp = process.env.CLINE_DESKTOP_APP;
if (!desktopApp) throw new Error("CLINE_DESKTOP_APP is required");

const bun = process.env.BUN_BIN || "bun";
const approvalToken = randomUUID();
const children: ReturnType<typeof Bun.spawn>[] = [];

async function reserveAvailablePort(): Promise<number> {
	return await new Promise((resolve, reject) => {
		const server = createServer();
		server.once("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const address = server.address();
			if (!address || typeof address === "string") {
				server.close();
				reject(new Error("Failed to reserve a sidecar port"));
				return;
			}
			server.close((error) => (error ? reject(error) : resolve(address.port)));
		});
	});
}

function spawn(command: string[], env: Record<string, string>) {
	const child = Bun.spawn(command, {
		cwd: desktopApp,
		env: { ...process.env, ...env },
		stdin: "inherit",
		stdout: "inherit",
		stderr: "inherit",
	});
	children.push(child);
	return child;
}

function stopChildren(): void {
	for (const child of children) {
		if (!child.killed) child.kill();
	}
}

process.on("SIGINT", stopChildren);
process.on("SIGTERM", stopChildren);

const sidecarPort = await reserveAvailablePort();
const endpoint = `ws://127.0.0.1:${sidecarPort}/transport?approval_token=${approvalToken}`;
const sidecar = spawn([bun, "run", "sidecar/index.ts"], {
	CLINE_SIDECAR_APPROVAL_TOKEN: approvalToken,
	CLINE_SIDECAR_PORT: String(sidecarPort),
});
const web = spawn(
	[bun, "run", "next", "dev", "webview", "-p", "3125", "-H", "127.0.0.1", "--turbo"],
	{ NEXT_PUBLIC_SIDECAR_WS_ENDPOINT: endpoint },
);

const exitCode = await Promise.race([sidecar.exited, web.exited]);
stopChildren();
await Promise.allSettled(children.map((child) => child.exited));
process.exit(exitCode);
