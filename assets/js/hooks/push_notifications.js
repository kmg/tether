// Push notifications hook for LiveView
import { setupPushNotifications } from "../push"

const PushNotificationsHook = {
  mounted() {
    this.updateButtonState()
  },

  reconnected() {
    this.updateButtonState()

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
    // Check current permission state
    if (!("Notification" in window)) {
      this.el.textContent = "Not Supported"
      this.el.disabled = true
      this.el.classList.remove("bg-blue-600", "hover:bg-blue-500")
      this.el.classList.add("bg-gray-600")
      return
    }

    if (Notification.permission === "granted") {
      // Check if we have an active subscription
      const reg = await navigator.serviceWorker.ready
      const subscription = await reg.pushManager.getSubscription()
      if (subscription) {
        this.el.textContent = "Notifications Enabled ✓"
        this.el.classList.remove("bg-blue-600", "hover:bg-blue-500")
        this.el.classList.add("bg-green-600")
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
