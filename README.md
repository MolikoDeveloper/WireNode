# WireNode

`WireNode` es el sidecar para macOS que empuja audio hacia `WireDeck` usando el protocolo remoto ya presente en `WireDeck`.

## Lo que queda implementado aquí

- daemon Zig para segundo plano
- UI local por HTTP en `http://127.0.0.1:17877`
- persistencia en `/etc/WireNode/config.json`
- plantilla `launchd` para iniciar antes de login
- transporte UDP compatible con `WireDeck`
- identidad estable de cliente por `client_id`

## Límite real de plataforma

Hay una restricción que conviene dejar explícita:

- `launchd` puede arrancar el daemon antes de login
- la captura real del audio del sistema en macOS no es equivalente a “leer el mixer global sin más”
- la vía moderna para hacerlo sin driver virtual firmado pasa por un backend Core Audio Tap y autorización del usuario
- por eso, el transporte, la UI y la persistencia ya están listas, pero el backend `system-default` se deja como punto de integración pendiente

Eso significa que hoy puedes validar el recorrido completo con `tone` o `silence`, y el siguiente paso técnico serio es implementar el capturador Core Audio Tap dentro de `WireNode`.

## Build

```bash
cd WireNode
zig build
```

## Configuración inicial

Escribe la configuración por defecto:

```bash
zig-out/bin/wirenode --write-default-config
```

Luego abre:

```text
http://127.0.0.1:17877
```

## Instalación en macOS

```bash
cd WireNode
./scripts/install-macos.sh
```

Ese script:

- instala el binario en `/usr/local/libexec/wirenode/wirenode`
- crea `/etc/WireNode/config.json` si no existe
- instala `assets/com.wiredeck.wirenode.plist` en `/Library/LaunchDaemons/`
- registra o reinicia el daemon con `launchctl`

## Compatibilidad con WireDeck

`WireNode` lleva una copia local del contrato de red en `src/protocol.zig`, compatible con el receptor ya presente en `WireDeck`. Del lado de `WireDeck`, esta entrega también corrige la identidad de fuentes remotas para que una entrada configurada en `WireNode` no cambie su `source_id` en cada reconexión.
