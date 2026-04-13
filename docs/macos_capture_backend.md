# macOS Capture Backend Notes

La parte pendiente en `WireNode` no es el transporte ni el daemon. El hueco real es el backend de captura del audio del sistema.

## Hecho confirmado

Apple documenta una ruta soportada para capturar audio de salida usando Core Audio Taps:

- `AudioHardwareCreateProcessTap`
- `CATapDescription`
- un aggregate device HAL que expone el tap como entrada

## Restricciones relevantes

- el sample oficial de Apple para Core Audio Taps requiere macOS 14.2 o superior
- para capturar audio del sistema hay que incluir `NSAudioCaptureUsageDescription`
- la primera vez que se empieza a grabar desde un aggregate device con tap, macOS muestra un prompt de permiso

## Implicación práctica para WireNode

Esto choca con la idea de “capturar audio del sistema antes del login y sin intervención previa del usuario”:

- `launchd` sí puede arrancar el servicio antes de login
- el backend de captura no queda plenamente operativo hasta que la app tenga autorización de system audio capture
- por eso el daemon, la UI local, la persistencia en `/etc/WireNode/config.json` y el transporte UDP ya están montados, pero `system-default` queda como integración futura

## Siguiente paso correcto

Implementar un backend macOS específico que:

1. cree el tap Core Audio
2. monte el aggregate device
3. lea los buffers PCM float32
4. los entregue al loop de envío UDP ya existente
5. gestione el estado de autorización y los errores de TCC de forma explícita
