// Web Push notification setup

export async function setupPushNotifications() {
  // Check if push is supported
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    console.log("Push notifications not supported")
    return false
  }

  try {
    // Register service worker
    const registration = await navigator.serviceWorker.register("/service-worker.js")
    console.log("Service worker registered")

    // Get VAPID public key from server
    const response = await fetch("/api/push/vapid-key")
    if (!response.ok) {
      console.log("VAPID key not configured on server")
      return false
    }
    const { vapid_public_key } = await response.json()

    // Request notification permission
    const permission = await Notification.requestPermission()
    if (permission !== "granted") {
      console.log("Notification permission denied")
      return false
    }

    // Subscribe to push
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(vapid_public_key),
    })

    // Send subscription to server
    await fetch("/api/push/subscribe", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ subscription: subscription.toJSON() }),
    })

    console.log("Push notifications enabled")
    return true
  } catch (error) {
    console.error("Failed to setup push notifications:", error)
    return false
  }
}

// Helper to convert VAPID key
function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const rawData = window.atob(base64)
  const outputArray = new Uint8Array(rawData.length)
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i)
  }
  return outputArray
}
