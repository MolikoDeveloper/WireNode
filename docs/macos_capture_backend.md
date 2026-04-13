# macOS Capture Backend Notes

`WireNode` ya usa Core Audio taps como backend de `system-default`. Este documento deja las decisiones y límites de esa integración.

## Hecho confirmado

Apple documenta una ruta soportada para capturar audio de salida usando Core Audio Taps:

- `AudioHardwareCreateProcessTap`
- `CATapDescription`
- un aggregate device HAL que expone el tap como entrada

## Restricciones relevantes

- el sample oficial de Apple para Core Audio Taps requiere macOS 14.2 o superior
- para capturar audio del sistema hay que incluir `NSAudioCaptureUsageDescription`
- la primera vez que se empieza a grabar desde un aggregate device con tap, macOS muestra un prompt de permiso

## Implementación actual

- `WireNode` crea un `CATapDescription` global estéreo
- crea un aggregate device privado a partir del tap
- registra un `AudioDeviceIOProcIDWithBlock`
- convierte los buffers a `float32` interleaved
- entrega esos frames al loop UDP ya existente

## Implicación práctica para WireNode

Esto sigue chocando con la idea de “capturar audio del sistema antes del login y sin intervención previa del usuario”:

- `launchd` sí puede arrancar el servicio antes de login
- el backend de captura no queda plenamente operativo hasta que el bundle tenga autorización de system audio capture
- por eso el binario instalado vive dentro de `WireNode.app`, con `NSAudioCaptureUsageDescription` en `Info.plist`
- si el servicio arranca antes de una sesión gráfica autorizada, el loop reintentará hasta que la captura pueda abrirse correctamente

## Siguiente paso correcto

1. endurecer el empaquetado para firma/codesign si fuese necesario
2. exponer en UI si se quiere `muteBehavior` configurable
3. detectar mejor estados de TCC frente a otros errores del HAL
4. reaccionar a cambios de sesión gráfica o reinicios del servicio CoreAudio
