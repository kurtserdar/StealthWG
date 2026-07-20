// Command stealthwg is the all-in-one masked WireGuard server: a daemon (`up`)
// plus setup CLI (`init`, `add-client`, `status`).
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"

	"github.com/kurtserdar/StealthWG/gateway/internal/wgserver"
)

const defaultConfigPath = "/etc/stealthwg/server.conf"

func configPath() string {
	if p := os.Getenv("STEALTHWG_CONFIG"); p != "" {
		return p
	}
	return defaultConfigPath
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "up":
		cmdUp()
	case "init":
		cmdInit(os.Args[2:])
	case "add-client":
		cmdAddClient(os.Args[2:])
	case "status":
		cmdStatus()
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: stealthwg <up | init [flags] | add-client NAME | status>")
}

func loadConfig() (*wgserver.Config, error) {
	data, err := os.ReadFile(configPath())
	if err != nil {
		return nil, err
	}
	return wgserver.ParseConfig(string(data))
}

func saveConfig(c *wgserver.Config) error {
	if i := strings.LastIndex(configPath(), "/"); i > 0 {
		if err := os.MkdirAll(configPath()[:i], 0o755); err != nil {
			return err
		}
	}
	return os.WriteFile(configPath(), []byte(c.Marshal()), 0o600)
}

func cmdUp() {
	cfg, err := loadConfig()
	if err != nil {
		fatal("load config (run 'stealthwg init' first): %v", err)
	}
	eng := &wgserver.Engine{}
	if err := eng.Start(cfg); err != nil {
		fatal("start: %v", err)
	}
	defer eng.Stop()
	fmt.Printf("stealthwg up: masked WireGuard on :%d, %d client(s)\n", cfg.ListenPort, len(cfg.Clients))

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	for s := range sig {
		if s == syscall.SIGHUP {
			if c, err := loadConfig(); err == nil {
				_ = eng.Reload(c)
				fmt.Println("reloaded peers")
			}
			continue
		}
		return
	}
}

func cmdInit(args []string) {
	requireRoot()
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	host := fs.String("public-host", "", "public IP or DNS name clients dial")
	subnet := fs.String("subnet", "10.8.0.0/24", "tunnel subnet (/24)")
	dns := fs.String("dns", "1.1.1.1", "client DNS")
	listen := fs.Int("listen", 51820, "WireGuard UDP port")
	transport := fs.String("transport", "mask", "transport: mask (UDP mask) or quic")
	sni := fs.String("sni", "", "TLS SNI presented by the QUIC transport (quic only)")
	_ = fs.Parse(args)

	if *transport != "mask" && *transport != "quic" {
		fatal("--transport must be 'mask' or 'quic'")
	}

	if _, err := os.Stat(configPath()); err == nil {
		fatal("config already exists at %s (use add-client, or remove it to re-init)", configPath())
	}
	ph := *host
	if ph == "" {
		ph = detectPublicHost()
	}
	if ph == "" {
		fatal("could not detect the public host; pass --public-host")
	}

	priv, _, err := wgserver.GenerateKeypair()
	if err != nil {
		fatal("keys: %v", err)
	}
	psk, err := wgserver.GeneratePSK()
	if err != nil {
		fatal("psk: %v", err)
	}
	cfg := &wgserver.Config{
		PrivateKey: priv, MaskKey: psk, ListenPort: *listen,
		Subnet: *subnet, PublicHost: ph, DNS: *dns,
		Transport: *transport, SNI: *sni,
	}
	if err := saveConfig(cfg); err != nil {
		fatal("save config: %v", err)
	}
	if !noSystemd() {
		_ = exec.Command("systemctl", "enable", "--now", "stealthwg").Run()
	}
	addClient(cfg, "client1")
	fmt.Println("\nStealthWG is up. Add more devices with: sudo stealthwg add-client <name>")
}

func cmdAddClient(args []string) {
	requireRoot()
	if len(args) < 1 {
		fatal("usage: stealthwg add-client NAME")
	}
	cfg, err := loadConfig()
	if err != nil {
		fatal("load config (run 'stealthwg init' first): %v", err)
	}
	addClient(cfg, args[0])
	reloadDaemon()
}

// noSystemd reports whether the CLI runs without systemd (containers), gated by
// the STEALTHWG_NO_SYSTEMD environment variable.
func noSystemd() bool { return os.Getenv("STEALTHWG_NO_SYSTEMD") != "" }

// reloadDaemon reloads the running server after a config change. Under systemd it
// asks systemctl; in a container it signals the daemon (PID 1) with SIGHUP, but
// only when PID 1 is actually stealthwg — so it is a no-op during entrypoint
// provisioning, when PID 1 is still the shell.
func reloadDaemon() {
	if noSystemd() {
		if c, err := os.ReadFile("/proc/1/comm"); err == nil &&
			strings.TrimSpace(string(c)) == "stealthwg" {
			_ = syscall.Kill(1, syscall.SIGHUP)
		}
		return
	}
	_ = exec.Command("systemctl", "reload", "stealthwg").Run()
}

func addClient(cfg *wgserver.Config, name string) {
	priv, pub, err := wgserver.GenerateKeypair()
	if err != nil {
		fatal("keys: %v", err)
	}
	addr, err := cfg.NextClientAddress()
	if err != nil {
		fatal("allocate address: %v", err)
	}
	cfg.Clients = append(cfg.Clients, wgserver.Client{Name: name, PublicKey: pub, Address: addr})
	if err := saveConfig(cfg); err != nil {
		fatal("save config: %v", err)
	}
	profile := cfg.ClientProfile(priv, addr)
	fmt.Printf("\n===== StealthWG client profile: %s (%s) =====\n%s\n", name, addr, profile)
	printQR(profile)
}

func cmdStatus() {
	out, _ := exec.Command("systemctl", "is-active", "stealthwg").Output()
	fmt.Printf("service: %s", string(out))
	if cfg, err := loadConfig(); err == nil {
		fmt.Printf("clients: %d\nlisten:  :%d\n", len(cfg.Clients), cfg.ListenPort)
	}
}

func detectPublicHost() string {
	out, err := exec.Command("sh", "-c", "curl -fsS https://api.ipify.org").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func printQR(profile string) {
	if _, err := exec.LookPath("qrencode"); err != nil {
		return
	}
	fmt.Println("----- scan this QR to import on a phone -----")
	cmd := exec.Command("qrencode", "-t", "ANSIUTF8")
	cmd.Stdin = strings.NewReader(profile)
	cmd.Stdout = os.Stdout
	_ = cmd.Run()
}

func requireRoot() {
	if os.Geteuid() != 0 {
		fatal("this command needs root (try: sudo stealthwg ...)")
	}
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", a...)
	os.Exit(1)
}
