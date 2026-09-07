import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { exec } from "node:child_process";

function runHook(command: string): Promise<string> {
	return new Promise((resolve) => {
		const child = exec(
			command,
			{
				timeout: 10_000,
				maxBuffer: 1024 * 1024,
				env: process.env,
			},
			(error, stdout) => {
				if (error) return resolve("");
				resolve(stdout.trim());
			},
		);

		child.stdin?.end();
	});
}

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", async (event) => {
		const instructions = process.env.BUOY_PI_INSTRUCTIONS;
		if (!instructions) return;

		const systemPrompt = `${event.systemPrompt}\n\n${instructions}`;
		const command = process.env.BUOY_CONTEXT_HOOK_COMMAND;
		if (!command) return { systemPrompt };

		const content = await runHook(command);
		if (!content) return { systemPrompt };

		return {
			systemPrompt,
			message: {
				customType: "buoy-neovim-context",
				content,
				display: false,
			},
		};
	});

	pi.on("tool_result", async (event) => {
		if (event.toolName !== "edit" && event.toolName !== "write") return;

		const command = process.env.BUOY_POST_TOOL_HOOK_COMMAND;
		if (!command) return;

		await runHook(command);
	});
}
