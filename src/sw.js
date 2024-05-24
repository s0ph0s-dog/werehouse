const cacheKey = "WerehouseCache";
const cacheVersion = "1";
const cacheName = cacheKey + ".v" + cacheVersion;
const precachedResources = [
  "/home",
  "/index.js",
  "/style.css",
  "/index.js",
  "/icon.svg",
];

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
  const cachedResponse = await caches.match(request);
  if (cachedResponse) {
    return cachedResponse;
  }
  try {
    const networkResponse = await fetch(request);
    if (networkResponse.ok) {
      const cache = await caches.open(cacheName);
      cache.put(request, networkResponse.clone());
    }
    return networkResponse;
  } catch (error) {
    return Response.error();
  }
}

async function cacheFirstWithRefresh(request) {
  const fetchResponsePromise = fetch(request).then(async (networkResponse) => {
    if (networkResponse.ok) {
      const cache = await caches.open(cacheName);
      cache.put(request, networkResponse.clone());
    }
    return networkResponse;
  });

  return (await caches.match(request)) || (await fetchResponsePromise);
}

async function networkFirst(request) {
  try {
    const networkResponse = await fetch(request);
    if (networkResponse.ok) {
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

self.addEventListener("activate", (event) => {
  event.waitUntil(clear_and_reset_cache());
});

self.addEventListener("fetch", (event) => {
  if (precachedResources.includes(url.pathname)) {
    event.respondWith(cacheFirst(event.request));
  } else if (
    url.pathname.includes("/queue-image/") ||
    url.pathname.includes("/image-file/")
  ) {
    event.respondWith(cacheFirstWithRefresh(event.request));
  } else {
    event.respondWith(networkFirst(event.request));
  }
});
