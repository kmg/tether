// Push notifications hook for LiveView
import { setupPushNotifications } from "../push"

const BASE_STYLE = "display:flex;flex-direction:column;align-items:center;gap:2px;min-width:40px"

const PushNotificationsHook = {
  mounted() {
    this.label = this.el.querySelector("span")
    this._enabled = false
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
      if (this._enabled) {
        await this.unsubscribe()
      } else {
        this.setState("setting-up")
        try {
          const success = await setupPushNotifications()
          this.setState(success ? "enabled" : "enable")
        } catch (error) {
          console.error("Push setup failed:", error)
          this.setState("enable")
        }
      }
    })
  },

  async unsubscribe() {
    this.setState("setting-up")
    try {
      const reg = await navigator.serviceWorker.ready
      const subscription = await reg.pushManager.getSubscription()
      if (subscription) {
        await subscription.unsubscribe()
        await fetch("/api/push/subscribe", {
          method: "DELETE",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ endpoint: subscription.endpoint }),
        })
      }
      this.setState("enable")
    } catch (error) {
      console.error("Push unsubscribe failed:", error)
      this.setState("enabled")
    }
  },

  setState(state) {
    this.el.disabled = false
    this.el.style.cssText = BASE_STYLE
    this._enabled = false

    switch (state) {
      case "not-supported":
        this.label.textContent = "Not supported"
        this.el.style.cssText = BASE_STYLE + ";color:#374151"
        this.el.disabled = true
        break
      case "enable":
        this.label.textContent = "Off"
        this.el.style.cssText = BASE_STYLE + ";color:#6b7280"
        break
      case "enabled":
        this.label.textContent = "On"
        this.el.style.cssText = BASE_STYLE + ";color:#4b5563"
        this._enabled = true
        break
      case "setting-up":
        this.label.textContent = "..."
        this.el.style.cssText = BASE_STYLE + ";color:#4b5563"
        this.el.disabled = true
        break
      case "blocked":
        this.label.textContent = "Blocked"
        this.el.style.cssText = BASE_STYLE + ";color:#4b5563"
        this.el.disabled = true
        break
    }
  },

  async updateButtonState() {
    if (!("Notification" in window)) {
      this.setState("not-supported")
      return
    }

    if (Notification.permission === "granted") {
      const reg = await navigator.serviceWorker.ready
      const subscription = await reg.pushManager.getSubscription()
      if (subscription) {
        this.setState("enabled")
        // Tell server this is the active endpoint, prune stale ones
        fetch("/api/push/confirm", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ endpoint: subscription.endpoint }),
        }).catch(() => {})
      } else {
        // Permission granted but subscription lost (iOS purges these)
        try {
          const success = await setupPushNotifications()
          if (success) this.setState("enabled")
        } catch (e) {
          console.warn("Auto-resubscribe failed:", e)
        }
      }
    } else if (Notification.permission === "denied") {
      this.setState("blocked")
    } else {
      this.setState("enable")
    }
  }
}

export default PushNotificationsHook
