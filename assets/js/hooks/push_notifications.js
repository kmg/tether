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
          this.el.textContent = "Notifications Enabled ✓"
          this.el.classList.remove("bg-blue-600", "hover:bg-blue-500")
          this.el.classList.add("bg-green-600")
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

  async updateButtonState() {
    if (!("Notification" in window)) {
      this.el.textContent = "Not Supported"
      this.el.disabled = true
      this.el.classList.remove("bg-blue-600", "hover:bg-blue-500")
      this.el.classList.add("bg-gray-600")
      return
    }

    if (Notification.permission === "granted") {
      const reg = await navigator.serviceWorker.ready
      const subscription = await reg.pushManager.getSubscription()
      if (subscription) {
        this.el.textContent = "Notifications Enabled ✓"
        this.el.classList.remove("bg-blue-600", "hover:bg-blue-500")
        this.el.classList.add("bg-green-600")
      } else {
        // Permission granted but subscription lost (iOS purges these)
        // Auto-resubscribe silently
        try {
          const success = await setupPushNotifications()
          if (success) {
            this.el.textContent = "Notifications Enabled ✓"
            this.el.classList.remove("bg-blue-600", "hover:bg-blue-500")
            this.el.classList.add("bg-green-600")
          }
        } catch (e) {
          console.warn("Auto-resubscribe failed:", e)
        }
      }
    } else if (Notification.permission === "denied") {
      this.el.textContent = "Blocked"
      this.el.disabled = true
      this.el.classList.remove("bg-blue-600", "hover:bg-blue-500")
      this.el.classList.add("bg-red-600")
    }
  }
}

export default PushNotificationsHook
