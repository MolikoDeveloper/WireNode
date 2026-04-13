# WireNode

`WireNode` es el sidecar para macOS que empuja audio hacia `WireDeck` usando el protocolo remoto ya presente en `WireDeck`.

## Lo que queda implementado aquí

- daemon Zig para segundo plano
- UI por HTTP en `http://<ip-de-tu-mac>:17877`
- persistencia en `/etc/WireNode/config.json`
- plantilla `launchd` para iniciar antes de login
- transporte UDP compatible con `WireDeck`
- identidad estable de cliente por `client_id`
- backend macOS `system-default` usando Core Audio taps

## Límite real de plataforma

Hay una restricción que conviene dejar explícita:

- `launchd` puede arrancar el daemon antes de login
- la captura real del audio del sistema en macOS no es equivalente a “leer el mixer global sin más”
- la vía soportada pasa por Core Audio taps y autorización del usuario
- el permiso se pide la primera vez que el binario corre desde un bundle con `NSAudioCaptureUsageDescription`
- una vez concedido, el sistema recuerda la autorización para ese bundle

Eso significa que hoy puedes validar con `system-default`, `tone`, `silence` o `stdin-f32le`. Lo que sigue después ya no es “capturar audio”, sino endurecer el empaquetado y el arranque de servicio.

## Build

```bash
cd WireNode
./scripts/build-macos.sh Debug
```

## Configuración inicial

Escribe la configuración por defecto:

```bash
zig-out/bin/wirenode --write-default-config
```

Luego abre:

```text
http://<ip-de-tu-mac>:17877
```

## Ejecutar desde un bundle local

Para que el prompt de permiso use el `Info.plist` correcto durante pruebas locales:

```bash
cd WireNode
./scripts/run-macos.sh
```

## Instalación en macOS

```bash
cd WireNode
./scripts/install-macos.sh
```

Ese script:

- compila `WireNode`
- instala el binario dentro de `/usr/local/libexec/WireNode.app`
- instala la `dylib` del backend macOS en `Contents/Frameworks`
- crea `/etc/WireNode/config.json` si no existe
- instala `assets/com.wiredeck.wirenode.plist` en `/Library/LaunchDaemons/`
- registra o reinicia el daemon con `launchctl`

## Compatibilidad con WireDeck

`WireNode` lleva una copia local del contrato de red en `src/protocol.zig`, compatible con el receptor ya presente en `WireDeck`. Del lado de `WireDeck`, esta entrega también corrige la identidad de fuentes remotas para que una entrada configurada en `WireNode` no cambie su `source_id` en cada reconexión.
