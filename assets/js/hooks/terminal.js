import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { WebLinksAddon } from "@xterm/addon-web-links"

// Unicode-safe base64 encoding: string → UTF-8 bytes → base64
// btoa() only handles Latin1, so we encode to UTF-8 first
function utf8ToBase64(str) {
  const bytes = new TextEncoder().encode(str)
  let binary = ''
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary)
}

const TerminalHook = {
  selectMode: false,
  lastSelection: null,
  isAdjustingViewport: false,
  outputReceived: false,

  async mounted() {
    // Wait for JetBrains Mono Nerd Font to load before initializing terminal
    await document.fonts.load("14px 'JetBrains Mono NF'")

    // Create terminal
    this.terminal = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'JetBrains Mono NF', monospace",
      scrollback: 10000,
      theme: {
        background: "#000000",
        foreground: "#ffffff",
        cursor: "#ffffff",
        cursorAccent: "#000000",
      },
      allowProposedApi: true,
    })

    // Add addons
    this.fitAddon = new FitAddon()
    this.terminal.loadAddon(this.fitAddon)
    this.terminal.loadAddon(new WebLinksAddon())

    // Open terminal in container
    this.terminal.open(this.el)
    this.fitAddon.fit()

    // Keep iOS keyboard open when tapping toolbar buttons.
    // Tapping a button blurs xterm's textarea, but refocusing during the
    // click handler is fast enough to prevent keyboard dismissal.
    const toolbar = document.getElementById('key-toolbar')
    if (toolbar) {
      toolbar.addEventListener('click', (e) => {
        if (e.target.closest('button, label')) {
          this.terminal.focus()
        }
      })
    }

    // Disable iOS keyboard features on xterm's hidden textarea — autocorrect
    // and autocapitalize trigger suggestion bar changes which fire visualViewport
    // events, and spellcheck causes layout interference
    if (this.terminal.textarea) {
      this.terminal.textarea.setAttribute('autocorrect', 'off')
      this.terminal.textarea.setAttribute('autocapitalize', 'off')
      this.terminal.textarea.setAttribute('spellcheck', 'false')
    }

    // Handle resize - skip if we're in the middle of viewport adjustment
    this.resizeObserver = new ResizeObserver(() => {
      if (this.isAdjustingViewport) return
      this.fitAddon.fit()
      this.sendResize()
    })
    this.resizeObserver.observe(this.el)

    // Handle iOS virtual keyboard via visualViewport resize
    // CSS property updates are immediate (layout), but terminal fit/resize/scroll are
    // debounced to prevent constant tmux redraws that gobble characters during typing.
    // On iOS, visualViewport events fire very frequently (keyboard suggestions, tiny scrolls).
    if (window.visualViewport) {
      this.handleViewportResize = () => {
        // CSS updates are immediate for responsive layout
        const vh = window.visualViewport.height
        const offsetTop = window.visualViewport.offsetTop
        document.documentElement.style.setProperty('--vv-height', `${vh}px`)
        document.documentElement.style.setProperty('--vv-offset', `${offsetTop}px`)

        // Debounce the expensive terminal operations
        if (this.viewportDebounce) clearTimeout(this.viewportDebounce)
        this.viewportDebounce = setTimeout(() => {
          this.isAdjustingViewport = true
          this.fitAddon.fit()
          this.sendResize()
          this.terminal.scrollToBottom()
          requestAnimationFrame(() => {
            this.isAdjustingViewport = false
          })
        }, 200)
      }
      window.visualViewport.addEventListener("resize", this.handleViewportResize)
      window.visualViewport.addEventListener("scroll", this.handleViewportResize)

      this.handleViewportResize()
    }

    // Send initial size and force tmux redraw at phone dimensions
    // (window may have been rendered at Mac width before we connected)
    this.sendResize()
    this.pushEvent("request_refresh", {})

    // Handle input - filter out SGR mouse events to prevent accidental TUI clicks
    // SGR mouse format: ESC[<button;col;rowM (press) or ESC[<button;col;rowm (release)
    const sgrMouseRegex = /\x1b\[<\d+;\d+;\d+[Mm]/g

    // Local echo for snappier feel on slow networks
    // Only echo printable characters, not escape sequences
    const isPrintable = (data) => data.length === 1 && data.charCodeAt(0) >= 32 && data.charCodeAt(0) < 127

    this.terminal.onData((data) => {
      // Filter out mouse events - they cause issues with Claude Code TUI
      const filtered = data.replace(sgrMouseRegex, '')
      if (filtered) {
        // Local echo for printable characters (mosh-like snappiness)
        // Skip if in select mode or if it's a control sequence
        if (!this.selectMode && isPrintable(filtered)) {
          // Don't echo - Claude Code handles its own input display
          // this.terminal.write(filtered)
        }
        this.pushEvent("terminal_input", { data: utf8ToBase64(filtered) })
      }
    })

    // Latency measurement - respond to pings
    this.handleEvent("ping", ({ ts }) => {
      this.pushEvent("pong", { ts })
    })

    // Latency display - updated via JS to avoid LiveView re-renders that steal focus
    this.handleEvent("latency_update", ({ avg }) => {
      const el = document.getElementById("latency-display")
      if (el) el.textContent = `${avg}ms`
    })

    // Handle output from server (base64 encoded)
    // Output is queued and written in requestAnimationFrame batches to avoid
    // DOM mutations during input event processing — on iOS, synchronous DOM
    // changes from terminal.write() can cause the hidden textarea to lose focus,
    // dropping keystrokes mid-typing.
    this.outputQueue = ''
    this.outputFlushScheduled = false

    this.handleEvent("terminal_output", ({ data }) => {
      // Hide loading overlay on first output
      if (!this.outputReceived) {
        this.outputReceived = true
        const overlay = document.getElementById("loading-overlay")
        if (overlay) {
          overlay.style.display = "none"
        }
      }

      const binaryString = atob(data)
      const bytes = new Uint8Array(binaryString.length)
      for (let i = 0; i < binaryString.length; i++) {
        bytes[i] = binaryString.charCodeAt(i)
      }
      const decoded = new TextDecoder('utf-8').decode(bytes)

      // Batch writes via rAF so input events get processed first
      this.outputQueue += decoded
      if (!this.outputFlushScheduled) {
        this.outputFlushScheduled = true
        requestAnimationFrame(() => {
          const queued = this.outputQueue
          this.outputQueue = ''
          this.outputFlushScheduled = false
          const hadFocus = document.activeElement === this.terminal.textarea
          this.terminal.write(queued)
          // iOS Safari can lose textarea focus during DOM mutations from write()
          if (hadFocus && document.activeElement !== this.terminal.textarea) {
            this.terminal.focus()
          }
        })
      }
    })

    // Handle select mode toggle from server
    this.handleEvent("toggle_select_mode", ({ enabled }) => {
      this.selectMode = enabled
      this.lastSelection = null  // Clear stored selection
      if (enabled) {
        // Clear any existing selection when entering select mode
        this.terminal.clearSelection()
      }
    })

    // Handle copy via direct DOM event (needed for iOS clipboard API)
    // JS.dispatch sends to document by default
    this.handleCopy = () => {
      const text = this.lastSelection || this.terminal.getSelection()
      if (text) {
        navigator.clipboard.writeText(text).catch(err => {
          console.error('Failed to copy:', err)
        })
      }
    }
    document.addEventListener("terminal:copy", this.handleCopy)

    // Handle paste - iOS long-press menu doesn't trigger xterm's onData
    // Use terminal.paste() which respects bracketed paste mode (wraps text in
    // ESC[200~ / ESC[201~ when enabled), so multi-line pastes don't execute
    // line-by-line. The pasted text flows through onData → terminal_input.
    this.el.addEventListener("paste", (e) => {
      e.preventDefault()
      const text = e.clipboardData?.getData("text")
      if (text) {
        this.terminal.paste(text)
      }
    })

    // Handle manual refresh button - full terminal recreation to fix rendering corruption
    this.handleRefresh = () => {
      this.recreateTerminal()
    }
    document.addEventListener("terminal:refresh", this.handleRefresh)


    // Handle paste button - only works on desktop, iOS use long-press instead
    this.handlePaste = async () => {
      try {
        const text = await navigator.clipboard.readText()
        if (text) {
          this.terminal.paste(text)
        }
      } catch (e) {
        // Clipboard API blocked on iOS - use native long-press paste instead
      }
    }
    document.addEventListener("terminal:paste", this.handlePaste)

    // Touch scrolling - sends arrow keys for tmux copy mode scrolling
    // In select mode, let xterm.js handle touch for selection instead
    let touchStartY = null
    let touchStartX = null
    let lastSentTime = 0
    const THROTTLE_MS = 50 // limit how fast we send keys

    this.el.addEventListener("touchstart", (e) => {
      if (e.touches.length === 1) {
        touchStartY = e.touches[0].clientY
        touchStartX = e.touches[0].clientX

        if (this.selectMode) {
          // In select mode, start selection at touch point
          const rect = this.el.getBoundingClientRect()
          const x = e.touches[0].clientX - rect.left
          const y = e.touches[0].clientY - rect.top
          // Convert pixel position to terminal cell coordinates
          const cellWidth = this.terminal.element.offsetWidth / this.terminal.cols
          const cellHeight = this.terminal.element.offsetHeight / this.terminal.rows
          const col = Math.floor(x / cellWidth)
          const row = Math.floor(y / cellHeight) + this.terminal.buffer.active.viewportY
          this.terminal.select(col, row, 0)
          this.selectionStartCol = col
          this.selectionStartRow = row
        }
      }
    }, { passive: true })

    this.el.addEventListener("touchmove", (e) => {
      if (touchStartY !== null && e.touches.length === 1) {
        if (this.selectMode) {
          // In select mode, extend selection
          const rect = this.el.getBoundingClientRect()
          const x = e.touches[0].clientX - rect.left
          const y = e.touches[0].clientY - rect.top
          const cellWidth = this.terminal.element.offsetWidth / this.terminal.cols
          const cellHeight = this.terminal.element.offsetHeight / this.terminal.rows
          const col = Math.floor(x / cellWidth)
          const row = Math.floor(y / cellHeight) + this.terminal.buffer.active.viewportY

          // Calculate selection length from start to current position
          const startOffset = this.selectionStartRow * this.terminal.cols + this.selectionStartCol
          const endOffset = row * this.terminal.cols + col
          const length = endOffset - startOffset

          this.terminal.select(this.selectionStartCol, this.selectionStartRow, length)
          return
        }

        // Scroll mode - send arrow keys
        const now = Date.now()
        if (now - lastSentTime < THROTTLE_MS) return

        const deltaY = e.touches[0].clientY - touchStartY
        const threshold = 15 // pixels to trigger a scroll

        if (Math.abs(deltaY) >= threshold) {
          // Send arrow key sequence for tmux copy mode
          // Swipe down = scroll up (see older content) = up arrow
          // Swipe up = scroll down (see newer content) = down arrow
          const arrowKey = deltaY > 0 ? "\x1b[A" : "\x1b[B"
          this.pushEvent("terminal_input", { data: btoa(arrowKey) })

          touchStartY = e.touches[0].clientY
          lastSentTime = now
        }
      }
    }, { passive: true })

    this.el.addEventListener("touchend", () => {
      // If in select mode, capture the selection before it might get cleared
      if (this.selectMode) {
        const selection = this.terminal.getSelection()
        if (selection) {
          this.lastSelection = selection
        }
      }
      touchStartY = null
      touchStartX = null
    }, { passive: true })

    // Handle page visibility change - force tmux redraw when returning from background
    // A same-size resize is a no-op for tmux, so we send request_refresh which
    // does a resize trick (rows-1 then rows) to force a full redraw
    this.handleVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        // Small delay to let browser settle after returning to foreground
        setTimeout(() => {
          this.fitAddon.fit()
          this.sendResize()
          this.pushEvent("request_refresh", {})
          this.terminal.focus()
        }, 100)
      }
    }
    document.addEventListener("visibilitychange", this.handleVisibilityChange)

    // Focus terminal
    this.terminal.focus()

    // Signal to server that we're ready - triggers a refresh to get initial content
    const { cols, rows } = this.terminal
    this.lastCols = cols
    this.lastRows = rows
    this.pushEvent("terminal_ready", { cols, rows })
  },

  sendResize() {
    const { cols, rows } = this.terminal
    // Reject garbage dimensions from mid-animation layout states —
    // iOS keyboard close can cause fitAddon.fit() to calculate cols=1,
    // which sends a bad resize to tmux → Claude Code renders at width 1
    if (cols < 10 || rows < 3) return
    // Skip if dimensions haven't changed — a same-size winsz still triggers SIGWINCH
    // in tmux, causing a full screen redraw that can eat characters during typing
    if (cols === this.lastCols && rows === this.lastRows) return
    this.lastCols = cols
    this.lastRows = rows
    this.pushEvent("terminal_resize", { cols, rows })
  },

  // Full terminal recreation to fix rendering corruption
  async recreateTerminal() {
    // Dispose old terminal
    if (this.terminal) {
      this.terminal.dispose()
    }

    // Wait for font
    await document.fonts.load("14px 'JetBrains Mono NF'")

    // Create fresh terminal
    this.terminal = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'JetBrains Mono NF', monospace",
      scrollback: 10000,
      theme: {
        background: "#000000",
        foreground: "#ffffff",
        cursor: "#ffffff",
        cursorAccent: "#000000",
      },
      allowProposedApi: true,
    })

    // Reattach addons
    this.fitAddon = new FitAddon()
    this.terminal.loadAddon(this.fitAddon)
    this.terminal.loadAddon(new WebLinksAddon())

    // Open in container
    this.terminal.open(this.el)
    this.fitAddon.fit()

    // Disable iOS keyboard features on recreated terminal
    if (this.terminal.textarea) {
      this.terminal.textarea.setAttribute('autocorrect', 'off')
      this.terminal.textarea.setAttribute('autocapitalize', 'off')
      this.terminal.textarea.setAttribute('spellcheck', 'false')
    }

    // Reattach input handler
    const sgrMouseRegex = /\x1b\[<\d+;\d+;\d+[Mm]/g
    this.terminal.onData((data) => {
      const filtered = data.replace(sgrMouseRegex, '')
      if (filtered) {
        this.pushEvent("terminal_input", { data: utf8ToBase64(filtered) })
      }
    })

    // Focus and trigger full redraw (sendResize alone won't redraw if size is unchanged)
    this.terminal.focus()
    this.sendResize()
    this.pushEvent("request_refresh", {})
  },

  // On LiveView reconnect (e.g., iOS background/foreground), the server creates a fresh
  // LiveView process with a new WindowSession, but mounted() doesn't fire again — only
  // reconnected(). Without re-pushing terminal_ready, the new WindowSession has zero
  // subscribers and all terminal output is silently dropped.
  reconnected() {
    const { cols, rows } = this.terminal
    this.lastCols = cols
    this.lastRows = rows
    this.pushEvent("terminal_ready", { cols, rows })
    this.terminal.focus()
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    if (window.visualViewport && this.handleViewportResize) {
      window.visualViewport.removeEventListener("resize", this.handleViewportResize)
      window.visualViewport.removeEventListener("scroll", this.handleViewportResize)
    }
    if (this.handleVisibilityChange) {
      document.removeEventListener("visibilitychange", this.handleVisibilityChange)
    }
    if (this.handleCopy) {
      document.removeEventListener("terminal:copy", this.handleCopy)
    }
    if (this.handleRefresh) {
      document.removeEventListener("terminal:refresh", this.handleRefresh)
    }
    if (this.handlePaste) {
      document.removeEventListener("terminal:paste", this.handlePaste)
    }
    if (this.terminal) {
      this.terminal.dispose()
    }
  },
}

export default TerminalHook
