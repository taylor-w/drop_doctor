// In-app guided tour — a self-contained, dependency-free spotlight walkthrough.
//
// Why client-side (no LiveView state): the dashboard re-patches on every sweep,
// and an overlay driven by server assigns would fight those patches and flicker.
// So, like the privacy/theme/timezone chrome, the tour lives entirely in the
// browser. It binds through event delegation on the document, so the trigger
// (`[data-tour-start]`, rendered in the navbar) keeps working across re-renders.
//
// Each step optionally anchors to a `[data-tour="<key>"]` marker placed on a real
// dashboard element. The element is re-queried every frame while the tour is open,
// so the spotlight tracks the target even as LiveView replaces nodes underneath it.
//
// Theming: the card and controls use the app's daisyUI tokens via `.tc-tour-*`
// classes (see app.css); the dimming wash matches the existing modal (black/55).
// Accessibility: it's a focus-trapped dialog with keyboard navigation, and it
// honours `prefers-reduced-motion`.

/**
 * Ordered walkthrough. `anchor` is the `data-tour` key of the element to spotlight
 * (null → a centered, target-less step). Keep `anchor` values in sync with the
 * `data-tour="..."` markers in the templates — `assets_pipeline_test.exs` asserts
 * every anchor here resolves to a rendered element, so drift fails the build.
 */
export const STEPS = [
  {
    anchor: null,
    title: "Welcome to DropDoctor",
    body:
      "When the internet stutters, this tells you whether it's you, your router, " +
      "or your ISP — with timestamped proof. Here's the 30-second tour.",
  },
  {
    anchor: "verdict",
    title: "The verdict, live",
    body:
      "The headline is DropDoctor's call right now: is the connection healthy, " +
      "and if not, who's most likely at fault. It updates continuously as new " +
      "readings come in.",
  },
  {
    anchor: "pipeline",
    title: "Follow the path",
    body:
      "Each hop from your device out to the wider web. A link lights up when it's " +
      "the weak one — click any segment to reveal the raw measurement behind it.",
  },
  {
    anchor: "controls",
    title: "Your controls",
    body:
      "Run a browser-based speed test, pause or resume monitoring, or force an " +
      "immediate re-check. Monitoring pauses automatically during a speed test.",
  },
  {
    anchor: "stability",
    title: "Stability at a glance",
    body:
      "Jitter, p99 latency, spikes and packet loss for your internet and router — " +
      "the numbers that explain stutter even when the average looks fine.",
  },
  {
    anchor: "history",
    title: "Recent history",
    body:
      "A rolling view of uptime and latency. Click it to expand the full timeline " +
      "and compare your router against your ISP side by side.",
  },
  {
    anchor: "report",
    title: "Save proof for your ISP",
    body:
      "Caught something? “Open report” launches a shareable report page at " +
      "/report — the verdict, per-segment evidence and every spike, timestamped " +
      "and ready to Save as PDF. The other buttons export the raw readings and " +
      "spike log as CSV, so you keep the receipts.",
  },
  {
    anchor: "privacy",
    title: "Stream-safe by a click",
    body:
      "About to screen-share? Blur or fully redact IPs, hostnames and timestamps " +
      "so nothing private leaks on stream — your readings keep flowing underneath.",
  },
  {
    anchor: "theme",
    title: "Make it yours",
    body:
      "Pick a light or dark mode and a colorway. Your choice is remembered and even " +
      "carries over to any report you export.",
  },
  {
    anchor: null,
    title: "You're all set",
    body:
      "That's the lot. Reopen this tour any time from the compass button in the " +
      "top-right. Happy diagnosing!",
  },
];

const PAD = 8; // breathing room (px) between spotlight and target edge
const FOCUSABLE = 'button, [href], [tabindex]:not([tabindex="-1"])';
const SEEN_KEY = "tc:tour-seen"; // localStorage marker: first-run tour shown

/**
 * Register the (single, idempotent) delegated click handler that launches the
 * tour, then auto-open it once on a first-time visitor. Safe to call on every
 * page load — it no-ops if already wired.
 */
export function initTour() {
  if (window.__tourInit) return;
  window.__tourInit = true;

  document.addEventListener("click", (e) => {
    const trigger = e.target.closest("[data-tour-start]");
    if (!trigger) return;
    e.preventDefault();
    startTour(trigger);
  });

  maybeAutoStart();
}

// Whether the first-run tour has already been shown. A throwing/blocked
// localStorage (private mode) counts as "seen" — we only auto-pop where we can
// actually remember having done so, so we never nag on every load.
function hasSeenTour() {
  try {
    return localStorage.getItem(SEEN_KEY) === "1";
  } catch (_) {
    return true;
  }
}

function markTourSeen() {
  try {
    localStorage.setItem(SEEN_KEY, "1");
  } catch (_) {
    /* ignore — private mode, storage disabled, etc. */
  }
}

// Greet a first-time visitor with the tour exactly once. Scoped to pages that
// carry the trigger (i.e. the dashboard) and deferred until the DOM is ready so
// the step anchors exist. Marked seen on open, so a reload mid-tour won't
// re-trigger it; the compass button still relaunches it on demand thereafter.
function maybeAutoStart() {
  if (hasSeenTour()) return;

  const run = () => {
    const trigger = document.querySelector("[data-tour-start]");
    if (!trigger) return; // not the dashboard — nothing to tour
    markTourSeen();
    startTour(trigger);
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run, { once: true });
  } else {
    run();
  }
}

let active = null; // the single live Tour instance, or null

/** Open the tour (no-op if one is already running). */
export function startTour(trigger) {
  if (active) return;
  active = new Tour(trigger || null);
  active.open();
}

class Tour {
  constructor(trigger) {
    this.trigger = trigger; // element to restore focus to on close
    this.index = 0;
    this.raf = 0;
    this.reduceMotion =
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    this.onKeydown = this.onKeydown.bind(this);
    this.track = this.track.bind(this);
  }

  open() {
    this.build();
    document.addEventListener("keydown", this.onKeydown, true);
    this.render();
    this.track(); // start the reposition loop
    // Focus the primary action once it exists so keyboard users land inside.
    this.nextBtn.focus();
  }

  build() {
    const root = document.createElement("div");
    root.className = "tc-tour-root";
    root.setAttribute("role", "dialog");
    root.setAttribute("aria-modal", "true");
    root.setAttribute("aria-labelledby", "tc-tour-title");
    root.setAttribute("aria-describedby", "tc-tour-body");
    if (this.reduceMotion) root.dataset.reduceMotion = "true";

    // Transparent full-screen catcher: blocks interaction with the page beneath
    // (true modality) without dismissing the tour on stray clicks.
    const catcher = document.createElement("div");
    catcher.className = "tc-tour-catch";

    // The lit "hole". Its huge box-shadow spread is what dims everything else.
    const spot = document.createElement("div");
    spot.className = "tc-tour-spot";

    const card = document.createElement("div");
    card.className = "tc-tour-card";

    const counter = document.createElement("div");
    counter.className = "tc-tour-counter";

    const title = document.createElement("h2");
    title.className = "tc-tour-title";
    title.id = "tc-tour-title";

    const body = document.createElement("p");
    body.className = "tc-tour-body";
    body.id = "tc-tour-body";

    const nav = document.createElement("div");
    nav.className = "tc-tour-nav";

    const skipBtn = button("Skip", "tc-tour-skip", () => this.close());
    const backBtn = button("Back", "tc-tour-back", () => this.go(-1));
    const nextBtn = button("Next", "tc-tour-next", () => this.go(1));

    const spacer = document.createElement("div");
    spacer.className = "tc-tour-spacer";

    nav.append(skipBtn, spacer, backBtn, nextBtn);
    card.append(counter, title, body, nav);
    root.append(catcher, spot, card);
    document.body.appendChild(root);

    Object.assign(this, {
      root,
      catcher,
      spot,
      card,
      counter,
      title,
      body,
      skipBtn,
      backBtn,
      nextBtn,
    });
  }

  go(delta) {
    const next = this.index + delta;
    if (next < 0) return;
    if (next >= STEPS.length) return this.close();
    this.index = next;
    this.render();
  }

  render() {
    const step = STEPS[this.index];
    this.counter.textContent = `${this.index + 1} / ${STEPS.length}`;
    this.title.textContent = step.title;
    this.body.textContent = step.body;
    this.backBtn.disabled = this.index === 0;
    this.nextBtn.textContent =
      this.index === STEPS.length - 1 ? "Done" : "Next";

    const el = step.anchor
      ? document.querySelector(`[data-tour="${step.anchor}"]`)
      : null;
    // A target-less step (or one whose anchor isn't on the page) centers the card.
    this.root.dataset.centered = el ? "false" : "true";

    if (el && !this.reduceMotion) {
      el.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
    } else if (el) {
      el.scrollIntoView({ block: "center", inline: "nearest" });
    }
    this.position();
  }

  // Re-measure on every frame so the spotlight follows scrolling, resizing and
  // LiveView DOM patches. Runs only while the tour is open.
  track() {
    this.position();
    this.raf = requestAnimationFrame(this.track);
  }

  position() {
    const step = STEPS[this.index];
    const el = step.anchor
      ? document.querySelector(`[data-tour="${step.anchor}"]`)
      : null;

    if (!el) {
      this.spot.style.opacity = "0";
      this.centerCard();
      return;
    }

    const r = el.getBoundingClientRect();
    const top = Math.max(r.top - PAD, 4);
    const left = Math.max(r.left - PAD, 4);
    const width = Math.min(r.width + PAD * 2, window.innerWidth - left - 4);
    const height = Math.min(r.height + PAD * 2, window.innerHeight - top - 4);

    Object.assign(this.spot.style, {
      opacity: "1",
      top: `${top}px`,
      left: `${left}px`,
      width: `${width}px`,
      height: `${height}px`,
    });

    this.placeCard(top, left, width, height);
  }

  // Position the card just below the spotlight, flipping above when there's no
  // room, and clamping into the viewport. Falls back to centered if it can't fit.
  placeCard(top, left, width, height) {
    const card = this.card;
    const cw = card.offsetWidth;
    const ch = card.offsetHeight;
    const gap = 12;
    const vw = window.innerWidth;
    const vh = window.innerHeight;

    const below = top + height + gap;
    const above = top - gap - ch;

    let y;
    if (below + ch <= vh - 4) y = below;
    else if (above >= 4) y = above;
    else return this.centerCard();

    // Horizontally align to the target's center, clamped to the viewport.
    let x = left + width / 2 - cw / 2;
    x = Math.max(8, Math.min(x, vw - cw - 8));

    Object.assign(card.style, {
      top: `${Math.round(y)}px`,
      left: `${Math.round(x)}px`,
      transform: "none",
    });
  }

  centerCard() {
    Object.assign(this.card.style, {
      top: "50%",
      left: "50%",
      transform: "translate(-50%, -50%)",
    });
  }

  onKeydown(e) {
    switch (e.key) {
      case "Escape":
        e.preventDefault();
        this.close();
        break;
      case "ArrowRight":
        e.preventDefault();
        this.go(1);
        break;
      case "ArrowLeft":
        e.preventDefault();
        this.go(-1);
        break;
      case "Tab":
        this.trapFocus(e);
        break;
    }
  }

  // Keep Tab focus cycling within the card's controls (a11y: modal dialog).
  trapFocus(e) {
    const items = [...this.card.querySelectorAll(FOCUSABLE)].filter(
      (n) => !n.disabled
    );
    if (!items.length) return;
    const first = items[0];
    const last = items[items.length - 1];
    const activeEl = document.activeElement;
    if (e.shiftKey && activeEl === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && activeEl === last) {
      e.preventDefault();
      first.focus();
    } else if (!this.card.contains(activeEl)) {
      e.preventDefault();
      first.focus();
    }
  }

  close() {
    if (!this.root) return;
    cancelAnimationFrame(this.raf);
    document.removeEventListener("keydown", this.onKeydown, true);
    this.root.remove();
    this.root = null;
    active = null;
    // Return focus to where the user left off (the trigger button).
    if (this.trigger && document.contains(this.trigger)) this.trigger.focus();
  }
}

function button(label, className, onClick) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = className;
  b.textContent = label;
  b.addEventListener("click", onClick);
  return b;
}
