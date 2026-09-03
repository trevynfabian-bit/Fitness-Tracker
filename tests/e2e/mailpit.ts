/**
 * Minimal Mailpit client. The local Supabase stack captures every outbound
 * auth email here, which is how the confirmation flow is exercised for real
 * instead of being stubbed.
 */

const MAILPIT_URL = process.env.MAILPIT_URL ?? "http://127.0.0.1:54324";

type MessageSummary = {
  ID: string;
  Subject: string;
  To: { Address: string }[];
  Created: string;
};

async function listMessages(): Promise<MessageSummary[]> {
  const response = await fetch(`${MAILPIT_URL}/api/v1/messages?limit=200`);
  if (!response.ok) {
    throw new Error(`Mailpit list failed: ${response.status}`);
  }
  const body = (await response.json()) as { messages: MessageSummary[] };
  return body.messages ?? [];
}

async function readMessage(id: string): Promise<string> {
  const response = await fetch(`${MAILPIT_URL}/api/v1/message/${id}`);
  if (!response.ok) {
    throw new Error(`Mailpit read failed: ${response.status}`);
  }
  const body = (await response.json()) as { HTML?: string; Text?: string };
  return body.HTML ?? body.Text ?? "";
}

export async function deleteAllMessages(): Promise<void> {
  await fetch(`${MAILPIT_URL}/api/v1/messages`, { method: "DELETE" });
}

/** Waits for the confirmation email sent to `address` and returns its link. */
export async function waitForConfirmationLink(
  address: string,
  timeoutMs = 30_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const messages = await listMessages();
    const match = messages.find((message) =>
      message.To.some((to) => to.Address.toLowerCase() === address.toLowerCase()),
    );

    if (match) {
      const html = await readMessage(match.ID);
      const link = html.match(/href="([^"]*\/auth\/confirm[^"]*)"/)?.[1];
      if (link) {
        return link.replace(/&amp;/g, "&");
      }
      throw new Error(
        `Confirmation email for ${address} contains no /auth/confirm link:\n${html}`,
      );
    }

    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  throw new Error(`No confirmation email arrived for ${address} within ${timeoutMs}ms`);
}
