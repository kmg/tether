// Service Worker for Tether PWA
// Cache strategy: static assets cached, HTML network-first, WebSocket pass-through

const CACHE_NAME = "tether-v4"

// Assets to precache on install
const PRECACHE = [
  "/",
  "/manifest.json",
  "/images/icon-192.png",
  "/images/icon-512.png",
  "/images/badge-72.png",
]

// Install - precache shell assets
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(PRECACHE)
    })
  )
  self.skipWaiting()
})

// Activate - clean old caches
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((names) => {
      return Promise.all(
        names
          .filter((name) => name !== CACHE_NAME)
          .map((name) => caches.delete(name))
      )
    })
  )
  self.clients.claim()
})

// Fetch - route requests to appropriate strategy
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url)

  // Skip non-GET requests
  if (event.request.method !== "GET") return

  // Skip WebSocket and LiveView long-poll
  if (url.pathname.startsWith("/live")) return

  // Skip Phoenix live reload in dev
  if (url.pathname.startsWith("/phoenix")) return

  // Digested assets (contain hash) - cache forever
  if (url.pathname.match(/\-[a-f0-9]{20,}\.(js|css|woff2?|png|jpg|svg)$/)) {
    event.respondWith(cacheFirst(event.request))
    return
  }

  // Static assets - cache with network fallback
  if (url.pathname.startsWith("/assets/") ||
      url.pathname.startsWith("/images/") ||
      url.pathname.startsWith("/fonts/")) {
    event.respondWith(cacheFirst(event.request))
    return
  }

  // HTML pages - network first, cache fallback
  if (event.request.headers.get("accept")?.includes("text/html")) {
    event.respondWith(networkFirst(event.request))
    return
  }

  // Everything else - network only
})

// Cache-first: try cache, fall back to network, update cache
async function cacheFirst(request) {
  const cached = await caches.match(request)
  if (cached) return cached

  try {
    const response = await fetch(request)
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME)
      cache.put(request, response.clone())
    }
    return response
  } catch (e) {
    // Offline and not cached - return error
    return new Response("Offline", { status: 503 })
  }
}

// Network-first: try network, fall back to cache
async function networkFirst(request) {
  try {
    const response = await fetch(request)
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME)
      cache.put(request, response.clone())
    }
    return response
  } catch (e) {
    // Network failed, try cache
    const cached = await caches.match(request)
    if (cached) return cached

    // Nothing cached, return offline page or error
    return new Response("Offline - no cached version available", {
      status: 503,
      headers: { "Content-Type": "text/html" }
    })
  }
}

// Push notification event
self.addEventListener("push", (event) => {
  const data = event.data ? event.data.json() : {}

  const tag = (data.data && data.data.tag) || undefined

  const options = {
    body: data.body || "Claude needs your input",
    icon: data.icon || "/images/icon-192.png",
    badge: data.badge || "/images/badge-72.png",
    vibrate: [200, 100, 200],
    data: data.data || {},
    actions: [
      { action: "open", title: "Open" },
      { action: "dismiss", title: "Dismiss" },
    ],
    requireInteraction: true,
    ...(tag && { tag, renotify: true }),
  }

  event.waitUntil(
    self.registration.showNotification(data.title || "Tether", options)
  )
})

// Notification click event
self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  if (event.action === "dismiss") return

  const data = event.notification.data || {}
  const targetUrl = data.session && data.window !== undefined
    ? `/terminal/${data.session}/${data.window}`
    : "/"

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes(self.location.origin) && "navigate" in client) {
          return client.navigate(targetUrl).then(() => client.focus())
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(targetUrl)
      }
    })
  )
})
