// Cross-origin isolation for static hosts that cannot send headers
// (GitHub Pages). Popcorn's VM uses threads, which need SharedArrayBuffer,
// which browsers only expose to cross-origin-isolated pages.
//
// Loaded as a classic <script> it registers itself as a service worker and
// reloads once; as a service worker it re-serves same-origin responses with
// the COOP/COEP headers that playground/serve.mjs sends directly.
if (typeof window === "undefined") {
  self.addEventListener("install", () => self.skipWaiting());
  self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

  self.addEventListener("fetch", (event) => {
    const request = event.request;
    if (request.cache === "only-if-cached" && request.mode !== "same-origin") return;
    if (new URL(request.url).origin !== self.location.origin) return;

    event.respondWith(
      fetch(request).then((response) => {
        if (response.status === 0) return response;
        const headers = new Headers(response.headers);
        headers.set("Cross-Origin-Opener-Policy", "same-origin");
        headers.set("Cross-Origin-Embedder-Policy", "require-corp");
        headers.set("Cross-Origin-Resource-Policy", "same-origin");
        return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
      }),
    );
  });
} else if (window.crossOriginIsolated) {
  sessionStorage.removeItem("troupe-coi-reload");
} else if ("serviceWorker" in navigator && window.isSecureContext) {
  // app.js waits instead of booting while this is set.
  window.__troupeIsolating = sessionStorage.getItem("troupe-coi-reload") !== "1";

  if (window.__troupeIsolating) {
    navigator.serviceWorker
      .register(document.currentScript.src)
      .then(() => navigator.serviceWorker.ready)
      .then(() => {
        sessionStorage.setItem("troupe-coi-reload", "1");
        location.reload();
      });
  }
}
