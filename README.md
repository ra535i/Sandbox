# Sandbox

A self-contained static website for sandbox testing — no frameworks, no build tools, no external dependencies. Everything works offline.

## Running locally

### Option 1 — VS Code Live Server (recommended)

1. Open the repository folder in VS Code.
2. Install the **Live Server** extension (ritwickdey.LiveServer) if you haven't already.
3. Right-click `index.html` in the Explorer panel and choose **"Open with Live Server"**.
4. Your browser will open automatically and hot-reload on every save.

### Option 2 — Python built-in HTTP server

```bash
# Python 3
python3 -m http.server 8080
# then open http://localhost:8080
```

### Option 3 — Any other static file server

Serve the repository root as a static directory with any tool you like (e.g. `npx serve .`, `caddy file-server`, etc.).

## What's inside

| File | Purpose |
|------|---------|
| `index.html` | Single-file app — all HTML, CSS, and JS in one place |
| `README.md` | This file |

## Features

- **Hero section** with a live clock that ticks every second.
- **Interactive Form Tester** covering every common input type:
  text, email, number, password (with show/hide toggle), date picker, dropdown, radio buttons, checkboxes, textarea, range slider with live value, and file upload.
- **Client-side validation** with inline error messages — no server required.
- **Success summary** that prints all submitted values in a green panel.
- **"Fill with random data"** button for quick testing.
- **"Clear form"** button.
- **Submission counter** stored in `localStorage` so it persists across page reloads.
- CSS fade-in animation on page load.
- Responsive layout that works on mobile and desktop.