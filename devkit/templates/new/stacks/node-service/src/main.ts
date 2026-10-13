// Process entry (Dockerfile CMD). Register dependency checks in the second argument of
// createApp as the service gains them (a database round-trip with a 3 s timeout, ...).
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";

const config = loadConfig();
const server = createApp(config);

server.listen(config.port, () => {
  // The boot line states what is enforced (observability.md, Logging).
  console.info(
    JSON.stringify({
      level: "info",
      msg: "__NAME__ listening",
      version: config.appVersion,
      port: config.port,
    }),
  );
});

// node is PID 1 in the image, so `docker stop` delivers SIGTERM here.
process.on("SIGTERM", () => {
  server.close(() => process.exit(0));
});
