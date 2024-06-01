const cacheKey = "WerehouseCache";
const cacheVersion = "6";
const cacheName = cacheKey + ".v" + cacheVersion;
const precachedResources = ["/index.js", "/style.css", "/icon.svg"];

async function precache() {
  const cache = await caches.open(cacheName);
  return cache.addAll(precachedResources);
}

async function clear_and_reset_cache() {
  caches.keys().then((names) => {
    for (let name of names) caches.delete(name);
  });
  return precache();
}

async function cacheFirst(request) {
  // console.log("Cache first:", request);
  const cachedResponse = await caches.match(request);
  if (cachedResponse) {
    return cachedResponse;
  }
  try {
    const networkResponse = await fetch(request);
    if (networkResponse.ok && !networkResponse.redirected) {
      const cache = await caches.open(cacheName);
      cache.put(request, networkResponse.clone());
    }
    return networkResponse;
  } catch (error) {
    return Response.error();
  }
}

async function cacheFirstWithRefresh(request) {
  // console.log("Cache first with refresh:", request);
  const fetchResponsePromise = fetch(request).then(async (networkResponse) => {
    if (networkResponse.ok && !networkResponse.redirected) {
      const cache = await caches.open(cacheName);
      cache.put(request, networkResponse.clone());
    }
    return networkResponse;
  });

  return (await caches.match(request)) || (await fetchResponsePromise);
}

async function networkFirst(request) {
  // console.log("Network first:", request);
  try {
    const networkResponse = await fetch(request);
    if (networkResponse.ok && !networkResponse.redirected) {
      const cache = await caches.open(cacheName);
      cache.put(request, networkResponse.clone());
    }
    return networkResponse;
  } catch (error) {
    const cachedResponse = await caches.match(request);
    return cachedResponse || Response.error();
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil(precache());
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (
    precachedResources.includes(url.pathname) ||
    url.pathname.includes("/queue-image/") ||
    url.pathname.includes("/image-file/")
  ) {
    event.respondWith(cacheFirstWithRefresh(event.request));
  }
});
