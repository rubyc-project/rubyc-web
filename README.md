# RubyC website

The single-page product website for [RubyC](https://github.com/rubyc-project), an independent C#-style compiler with native and JIT output. Built with **Blazor WebAssembly and .NET 10**.

## Features

- Animated ruby crystal, orbital paths, and a dark responsive design.
- Original RubyC logo and product information based on the compiler documentation.
- Three interactive, syntax-highlighted examples with copyable CLI commands.
- Benchmark comparisons for binary size, runtime, and compile time.
- Compiler architecture, development roadmap, and a contributor invitation.
- Mobile navigation, keyboard-accessible controls, and reduced-motion support.

The examples are illustrative: this website does **not** run the RubyC compiler in the browser. Benchmark values reproduce the compiler README's hello-world snapshot; the page includes measurement conditions and linking differences.

## Requirements

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).
- A browser with WebAssembly support.

No Node.js build step or JavaScript framework is required. Typography uses Google Fonts with system-font fallbacks.

## Run locally

```sh
git clone https://github.com/rubyc-project/rubyc-web.git
cd rubyc-web
dotnet restore rubyc-web.sln
dotnet run --project rubyc-web/rubyc-web.csproj --urls http://localhost:5188
```

Open [localhost:5188](http://localhost:5188).

For automatic rebuilds during development:

```sh
dotnet watch --project rubyc-web/rubyc-web.csproj run --urls http://localhost:5188
```

## Build and publish

```sh
dotnet build rubyc-web.sln -c Release
dotnet publish rubyc-web/rubyc-web.csproj -c Release
```

Publish output is written to:

```text
rubyc-web/bin/Release/net10.0/publish/wwwroot/
```

Host the contents of that directory on a static web server. Configure a fallback to `index.html` for client-side routes and serve WebAssembly files with the appropriate MIME type (`application/wasm`). The site currently uses `<base href="/">`; adjust this before deploying under a subpath such as `/rubyc-web/`.

For additional WebAssembly build optimizations, install the optional SDK workload before publishing:

```sh
dotnet workload install wasm-tools
```

## Project structure

```text
rubyc-web.sln
rubyc-web/
  Pages/Home.razor          # Landing page, examples, and benchmark data
  Pages/NotFound.razor      # Unknown-route view
  Layout/MainLayout.razor   # Page layout
  App.razor                # Client-side routing
  Program.cs               # WebAssembly application startup
  wwwroot/
    css/app.css            # Responsive styles and animations
    images/logo.png        # RubyC logo
    js/site.js             # Clipboard and keyboard helpers
    index.html             # Host page and bootstrapping
```

## Editing content

Update page content, code examples, and benchmark values in `Pages/Home.razor`. Keep benchmark values paired with their workload, units, and methodology; do not mix measurements from different runs. Edit colors, layouts, and motion in `wwwroot/css/app.css`.

When making visual changes, check desktop and mobile layouts, navigation, example switching, command copying, all benchmark metrics, and the methodology disclosure. Also check keyboard navigation and reduced-motion behavior.

## Contributing

Contributions to the website are welcome through issues and pull requests in this repository. For the compiler itself, explore the projects in the [RubyC GitHub organization](https://github.com/rubyc-project).

## Container and cluster deployment

The `deploy/` directory contains a multistage Dockerfile, Nginx configuration, Kubernetes templates, and a repeatable deployment script. See [deploy/README.md](deploy/README.md) for requirements, DNS/TLS setup, verification, and rollback.

```sh
./deploy/deploy.sh
```

The deployment targets namespace `rubyc` on the server node and serves `https://rubyc.org` through the existing IPv4 and IPv6 ingress listeners.
