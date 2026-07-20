# StealthWG

**English** · [Türkçe](#stealthwg-türkçe)

A **masked WireGuard** for networks that fingerprint and block plain WireGuard via
DPI (Deep Packet Inspection): a client app for **iOS and macOS**, and a
self-hostable **masked WireGuard server**.

StealthWG does **not** reimplement WireGuard. It builds on the official,
MIT-licensed WireGuard engine (`wireguard-go`) and inserts a masking layer at the
UDP socket boundary, so the bytes on the wire no longer match WireGuard's
fingerprint — while WireGuard itself provides all the real cryptography.

```
Plain WireGuard:  WG engine ─────────────────────────► server:51820
StealthWG:        WG engine ─► mask ─► noise on wire ─► unmask ─► WG
```

## Why this exists

Standard WireGuard is easy for a network operator to recognize: its handshake
packets have a fixed shape — a message-type byte followed by reserved zero bytes,
plus fixed 148/92-byte sizes. Both fixed-line ISPs and mobile carriers use exactly
this signature to block WireGuard on **every** port, so the tunnel never connects,
no matter how you configure it — while ordinary UDP keeps flowing.

StealthWG reshapes every packet into high-entropy, variable-length noise, so the
operator sees no recognizable WireGuard pattern to match — yet WireGuard still
provides all the security. Validated in practice: masked WireGuard completed a
handshake and carried live traffic (internet and LAN) over a mobile carrier that
blocks plain WireGuard on every port.

## Features

- **Cross-platform client** — native **iOS** and **macOS** apps sharing one code
  base (masking, connection, stats, profiles).
- **Traffic masking** — the UdpMask codec turns WireGuard packets into
  high-entropy noise; a pluggable `Obfuscator` seam leaves room for future
  transports (e.g. QUIC).
- **Multiple endpoints with automatic fallback** — the client tries several server
  endpoints (e.g. `:51819` then `:443`) until one completes a handshake.
- **Multiple profiles + editing** — hold several servers, switch between them, edit
  in a structured form; generate a client keypair on device or paste your own.
- **Kill switch + on-demand** — per profile: always-on auto-connect, route all
  traffic (no leaks), and keep the LAN reachable.
- **Easy import/export** — paste, scan a QR, import a `.conf`, or build from
  scratch; export any profile as a QR.
- **Self-hostable server, two shapes** — an **all-in-one** masked WireGuard server
  (one native binary; `apt install` + `stealthwg init`) or a **relay** that masks
  in front of an existing WireGuard (Docker / RouterOS / Kubernetes).
- **Privacy by design** — no logging of user traffic; keys never leave the device;
  masking is fingerprint-breaking only, not a second crypto layer.

## How the masking works

The masking lives in one small piece, reused on both ends — exactly the symmetry
that makes the design simple:

- **Client (iOS/macOS)** — the app runs `wireguard-go`; a `MaskBind` (in `wgbind`)
  wraps its UDP `conn.Bind` and applies the `mask` codec — sealing outbound,
  opening inbound — at the socket. The masking is pluggable behind a Go
  `Obfuscator` interface (`Seal`/`Open`).
- **Server** — either the **all-in-one** `stealthwg` server (embeds the *same*
  `wireguard-go` + `MaskBind`, so it terminates the masked tunnel directly), or the
  **relay** `stealthwg-gateway` (unmasks and forwards plain WireGuard to an
  unmodified upstream WireGuard).

The mask codec is symmetric: the client seals what the server opens, and vice
versa. All cryptographic security remains WireGuard's.

## Installation

See **[INSTALL.md](INSTALL.md)** for step-by-step instructions — building the
iOS/macOS app, and standing up a server (all-in-one native package or relay). Deep
server reference: **[docs/deploy-gateway.md](docs/deploy-gateway.md)**.

The app imports a standard wg-quick config with a StealthWG `[Stealth]` section
(`MaskKey`, and optional fallback `Endpoints`):

```ini
[Interface]
PrivateKey = <client private key>
Address = 10.0.0.2/32

[Peer]
PublicKey = <server public key>
Endpoint = <server public IP>:51819
AllowedIPs = 0.0.0.0/0

[Stealth]
MaskKey = <base64 PSK>
Endpoints = <host>:51819, <host>:443
```

## Status

Working masked WireGuard: validated end-to-end (handshake + live traffic) from a
physical iPhone over a carrier that blocks plain WireGuard, through a self-hosted
gateway. Client apps (iOS/macOS) and both server shapes are built; hardening and
distribution are ongoing.

## License

[MIT](LICENSE). Built on the MIT-licensed WireGuard projects.

---

# StealthWG (Türkçe)

[English](#stealthwg) · **Türkçe**

DPI (Derin Paket İncelemesi) ile düz WireGuard'ı parmak izinden tanıyıp engelleyen
ağlar için **maskeli WireGuard**: **iOS ve macOS** için bir istemci uygulaması ve
kendi sunucunda barındırabileceğin bir **maskeli WireGuard sunucusu**.

StealthWG, WireGuard'ı **yeniden yazmaz**. Resmi, MIT lisanslı WireGuard motorunun
(`wireguard-go`) üzerine kurulur ve UDP soket sınırına bir maskeleme katmanı
yerleştirir; böylece teldeki baytlar WireGuard'ın parmak iziyle eşleşmez — ama tüm
gerçek kriptografiyi yine WireGuard sağlar.

```
Düz WireGuard:  WG motoru ────────────────────────────► sunucu:51820
StealthWG:      WG motoru ─► maske ─► telde gürültü ──► maskeyi kaldır ─► WG
```

## Neden bu proje?

Standart WireGuard, bir ağ operatörü için tanınması kolaydır: el sıkışma paketleri
sabit bir desene sahiptir — bir mesaj-tipi baytı, ardından sıfır baytlar ve sabit
148/92 baytlık boyutlar. Hem sabit hat sağlayıcıları hem de GSM operatörleri tam
olarak bu parmak izini kullanıp WireGuard'ı **her portta** engeller; nasıl
yapılandırırsan yapılandır tünel kurulmaz — oysa sıradan UDP akmaya devam eder.

StealthWG her paketi yüksek entropili, değişken uzunlukta gürültüye dönüştürür;
böylece operatör eşleştirebileceği tanıdık bir WireGuard deseni göremez — ama
güvenliği yine WireGuard sağlar. Pratikte doğrulandı: maskeli WireGuard, düz
WireGuard'ı her portta engelleyen bir GSM operatörünün mobil verisi üzerinden el
sıkışmayı tamamladı ve canlı trafik (internet ve LAN) taşıdı.

## Özellikler

- **Çok platformlu istemci** — tek kod tabanını paylaşan native **iOS** ve **macOS**
  uygulamaları (maskeleme, bağlantı, istatistik, profiller).
- **Trafik maskeleme** — UdpMask codec'i WireGuard paketlerini yüksek entropili
  gürültüye çevirir; takılabilir bir `Obfuscator` arayüzü ileride yeni taşımalara
  (ör. QUIC) yer bırakır.
- **Çoklu endpoint + otomatik yedekleme** — istemci birden çok sunucu endpoint'ini
  (ör. önce `:51819`, sonra `:443`) el sıkışma olana kadar sırayla dener.
- **Çoklu profil + düzenleme** — birden çok sunucu tut, aralarında geç, yapısal
  formda düzenle; cihazda anahtar üret ya da kendininkini yapıştır.
- **Kill switch + on-demand** — profil başına: her zaman-açık otomatik bağlan, tüm
  trafiği tünelden geçir (sızıntısız), yerel ağ erişimini koru.
- **Kolay içe/dışa aktarma** — yapıştır, QR tara, `.conf` içe aktar veya sıfırdan
  oluştur; herhangi bir profili QR olarak dışa aktar.
- **Kendi sunucun, iki biçim** — **all-in-one** maskeli WireGuard sunucusu (tek
  native binary; `apt install` + `stealthwg init`) ya da mevcut WireGuard'ın önüne
  maske koyan bir **relay** (Docker / RouterOS / Kubernetes).
- **Tasarımdan gizlilik** — kullanıcı trafiği loglanmaz; anahtarlar cihazdan çıkmaz;
  maskeleme yalnızca parmak izini bozar, ikinci bir şifreleme katmanı değildir.

## Maskeleme nasıl çalışır

Maskeleme, iki uçta da tekrar kullanılan tek bir küçük parçada yaşar — tasarımı
basit kılan simetri budur:

- **İstemci (iOS/macOS)** — uygulama `wireguard-go` çalıştırır; bir `MaskBind`
  (`wgbind` içinde) onun UDP `conn.Bind`'ını sarar ve `mask` codec'ini uygular —
  gideni sealler, geleni açar — soket sınırında. Maskeleme, Go `Obfuscator`
  arayüzünün (`Seal`/`Open`) arkasında takılabilirdir.
- **Sunucu** — ya **all-in-one** `stealthwg` sunucusu (*aynı* `wireguard-go` +
  `MaskBind`'i gömer, maskeli tüneli doğrudan sonlandırır), ya da **relay**
  `stealthwg-gateway` (maskeyi açıp değiştirilmemiş bir WireGuard'a düz WireGuard
  olarak iletir).

Mask codec'i simetriktir: istemcinin seallediğini sunucu açar, tersi de geçerli.
Tüm kriptografik güvenlik WireGuard'da kalır.

## Kurulum

Adım adım talimatlar için **[INSTALL.md](INSTALL.md)** — iOS/macOS uygulamasının
derlenmesi ve bir sunucunun (all-in-one native paket ya da relay) ayağa
kaldırılması. Derin sunucu referansı: **[docs/deploy-gateway.md](docs/deploy-gateway.md)**.

Uygulama, StealthWG `[Stealth]` bölümü (`MaskKey` ve opsiyonel yedek `Endpoints`)
olan standart bir wg-quick config'i içe aktarır:

```ini
[Interface]
PrivateKey = <istemci özel anahtarı>
Address = 10.0.0.2/32

[Peer]
PublicKey = <sunucu açık anahtarı>
Endpoint = <sunucu public IP>:51819
AllowedIPs = 0.0.0.0/0

[Stealth]
MaskKey = <base64 PSK>
Endpoints = <host>:51819, <host>:443
```

## Durum

Çalışan maskeli WireGuard: fiziksel bir iPhone'dan, düz WireGuard'ı engelleyen bir
operatör üzerinden, kendi barındırdığımız bir gateway ile uçtan uca (el sıkışma +
canlı trafik) doğrulandı. İstemci uygulamaları (iOS/macOS) ve her iki sunucu biçimi
inşa edildi; sertleştirme ve dağıtım sürüyor.

## Lisans

[MIT](LICENSE). MIT lisanslı WireGuard projeleri üzerine kuruludur.
