// Push notifications hook for LiveView
import { setupPushNotifications } from "../push"

const PushNotificationsHook = {
  mounted() {
    this.setupClickHandler()
    this.updateButtonState()
  },

  reconnected() {
    this.updateButtonState()
  },

  setupClickHandler() {
    if (this._clickBound) return
    this._clickBound = true

    this.el.addEventListener("click", async () => {
      this.el.textContent = "Setting up..."
      this.el.disabled = true

      try {
        const success = await setupPushNotifications()
        if (success) {
          this.setCompact("Push ✓", "bg-green-700")
        } else {
          this.el.textContent = "Failed - Tap to Retry"
          this.el.disabled = false
        }
      } catch (error) {
        console.error("Push setup failed:", error)
        this.el.textContent = "Error - Tap to Retry"
        this.el.disabled = false
      }
    })
  },

  setCompact(text, bgClass) {
    this.el.textContent = text
    this.el.classList.remove("bg-blue-600", "hover:bg-blue-500", "px-3", "py-1.5")
    this.el.classList.add(bgClass, "px-2", "py-1", "text-xs")
  },

  async updateButtonState() {
    if (!("Notification" in window)) {
      this.setCompact("N/A", "bg-gray-600")
      this.el.disabled = true
      return
    }

    if (Notification.permission === "granted") {
      const reg = await navigator.serviceWorker.ready
      const subscription = await reg.pushManager.getSubscription()
      if (subscription) {
        this.setCompact("Push ✓", "bg-green-700")
        // Tell server this is the active endpoint, prune stale ones
        fetch("/api/push/confirm", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ endpoint: subscription.endpoint }),
        }).catch(() => {})
      } else {
        // Permission granted but subscription lost (iOS purges these)
        // Auto-resubscribe silently
        try {
          const success = await setupPushNotifications()
          if (success) {
            this.setCompact("Push ✓", "bg-green-700")
          }
        } catch (e) {
          console.warn("Auto-resubscribe failed:", e)
        }
      }
    } else if (Notification.permission === "denied") {
      this.setCompact("Blocked", "bg-red-700")
      this.el.disabled = true
    }
  }
}

export default PushNotificationsHook
