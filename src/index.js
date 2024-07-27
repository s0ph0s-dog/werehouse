async function registerServiceWorker() {
  if ("serviceWorker" in navigator) {
    try {
      const registration = await navigator.serviceWorker.register("/sw.js", {
        scope: "/",
      });
      if (registration.installing) {
        // console.log("Service worker installing");
      } else if (registration.waiting) {
        // console.log("Service worker installed");
      } else if (registration.active) {
        // console.log("Service worker active");
      }
    } catch (error) {
      console.error(`Registration failed with ${error}`);
    }
  }
}

registerServiceWorker();

htmx.onLoad(function (content) {
  let cancelButtons = content.querySelectorAll('[name="cancel"]');
  cancelButtons.forEach((btn) => {
    btn.addEventListener("click", (e) => {
      console.log("cancelling");
      btn.closest("dialog").close();
    });
  });
});
