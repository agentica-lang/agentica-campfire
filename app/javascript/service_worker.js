// Registers the service worker of the app (`/service-worker.js`), which keeps the stylesheet and this script for the
// installed app. A browser without service workers, or a failed registration, changes nothing.
export function startServiceWorker() {
  if (!("serviceWorker" in navigator)) return;
  navigator.serviceWorker.register("/service-worker.js").catch(function () {});
}
