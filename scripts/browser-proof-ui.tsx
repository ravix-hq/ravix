import { createRoot } from "react-dom/client";
import { SharedBrowser } from "../src/components/SharedBrowser";
import "../src/styles.css";

createRoot(document.getElementById("root")!).render(<main style={{ maxWidth: 760, margin: "40px auto", padding: 16 }}>
  <h1>Shared browser · local proof</h1>
  <p>Fixture URL: <code>{location.origin}/fixture</code></p>
  <p>Open the browser, take control, and visit the fixture. Enter a name and save it, then checkpoint the session.</p>
  <SharedBrowser trackId="proof" owner />
</main>);
