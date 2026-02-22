// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/tether"
import topbar from "../vendor/topbar"

// Tether-specific imports
import TerminalHook from "./hooks/terminal"
import PushNotificationsHook from "./hooks/push_notifications"

// File upload hook for PDF/document attachments
const FileUploadHook = {
  mounted() {
    this.el.addEventListener("change", (e) => {
      const file = e.target.files[0]
      if (!file) return

      const reader = new FileReader()
      reader.onload = () => {
        const base64 = reader.result.split(",")[1]
        this.pushEvent("paste_file", {
          data: base64,
          type: file.type,
          name: file.name
        })
      }
      reader.readAsDataURL(file)
      // Reset input so same file can be selected again
      e.target.value = ""
    })
  }
}

// Custom hooks
const Hooks = {
  ...colocatedHooks,
  Terminal: TerminalHook,
  PushNotifications: PushNotificationsHook,
  FileUpload: FileUploadHook,
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// Force longpoll on slow networks (add ?longpoll to URL)
const forceLongpoll = new URLSearchParams(window.location.search).has('longpoll')

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: forceLongpoll ? 0 : 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// Register service worker for push notifications
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/service-worker.js")
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

