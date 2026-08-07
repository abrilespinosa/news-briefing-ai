# 09 · Entrega

## Objetivo

Sacar el briefing de la base de datos y ponerlo delante de una persona. Es la última fase del pipeline y la única cuyo resultado no es una fila en una tabla.

## Arquitectura

### Por qué un adjunto de Telegram y no una web

El plan inicial era servir el HTML por un Webhook de n8n y mandar un aviso a Telegram con el enlace. Se descartó al comprobar una restricción del entorno real, no del diseño: **el portátil que aloja el pipeline se suspende al minuto de inactividad** (`pmset sleep 1`). Cualquier entrega basada en un enlace —túnel público o IP de la red local— apunta a un servidor que estará dormido justo cuando el destinatario abra la notificación por la mañana.

Un adjunto no tiene ese problema: viaja a los servidores de Telegram en el momento del envío y se lee con el ordenador apagado.

Esto solo funciona porque el HTML que produce 08 es **autocontenido**: cero hojas de estilo externas, cero fuentes remotas, cero imágenes, cero JavaScript. Se verificó sobre el documento almacenado antes de decidir el canal. Un HTML con una sola dependencia externa se vería roto al abrirlo desde el móvil.

Telegram no renderiza HTML en el cuerpo de un mensaje —ni tablas, que son el elemento central del briefing—, así que el mensaje es solo el aviso y el documento va como fichero.

### El mensaje: tres piezas, ninguna redundante

```
<b>Briefing · 7 de agosto de 2026</b>
30 acontecimientos · 7 medios
[briefing-2026-08-07.html]
Ten un buen día.
```

La cabecera anuncia, no resume: fecha y dos cifras. Adelantar un titular o una discrepancia obligaría a leer dos veces lo mismo, y el criterio del proyecto es que el briefing se lee entero o no se lee.

El número de medios sale del `payload`, no de la configuración: cuenta los que **realmente aparecen** en el briefing de ese día. Con ocho fuentes configuradas, un día cualquiera alguna no aporta ningún cluster multi-fuente.

### Dónde vive el destinatario

El `chat_id` no es una credencial —sin el token del bot no sirve de nada— pero sí un identificador personal, y el JSON de los workflows se versiona en un repositorio público. La opción natural era una variable de entorno leída con `{{ $env.TELEGRAM_CHAT_ID }}`.

**No funciona en n8n 2.x.** El acceso a variables de entorno desde las expresiones está denegado por defecto:

```js
// n8n-workflow/dist/cjs/workflow-data-proxy-env-provider.js
const isEnvAccessBlocked = process.env.N8N_BLOCK_ENV_ACCESS_IN_NODE !== 'false';
```

El error que devuelve, `access to env vars denied`, no menciona la variable que hay que definir salvo en el detalle de la causa. Las tres salidas y por qué se eligió la tercera:

| Opción | Descartada porque |
|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` | El permiso es global: cualquier expresión de cualquier workflow pasaría a leer **todas** las variables del contenedor, incluida `POSTGRES_PASSWORD`. Además quedaría en el `docker-compose.yml` público como una relajación de seguridad sin contexto |
| Variables nativas de n8n (`$vars`) | Función de licencia de pago: la API responde `403 feat:variables` |
| **Tabla `app_config` en Postgres** | ✅ Elegida |

Postgres ya es el contrato entre fases, así que el valor se lee de ahí. Y sin añadir ningún nodo: viaja como subconsulta dentro del `SELECT` que 09 ya hacía sobre `briefings`, porque no depende de la fila.

```sql
SELECT b.briefing_date, b.cluster_count, b.divergence_count, b.payload, b.content_html,
       (SELECT value FROM app_config WHERE key = 'telegram_chat_id') AS chat_id
FROM briefings b
WHERE b.briefing_date = (now() AT TIME ZONE 'UTC')::date;
```

Si la clave faltara, `chat_id` llega `NULL` y Telegram falla ruidosamente. Es deliberado no comprobarlo en el `IF`: un briefing que no se entrega no debe pasar por entregado.

El corte temporal es el **día natural UTC**, el mismo con el que 08 lo construyó. Con otro criterio se podría entregar un briefing distinto del que se generó.

## Implementación

```
Execute Workflow Trigger
  → Get Today's Briefing (Postgres, alwaysOutputData)
  → Anything to Deliver? (IF)
      true  → Build Telegram Payload (Code)
            → Send Header            (Telegram, sendMessage)
            → Restore Payload        (Code)
            → Convert Briefing to File (convertToFile, toText)
            → Send Briefing Document (Telegram, sendDocument)
            → Send Sign-off          (Telegram, sendMessage)
      false → Nothing to Deliver (NoOp)
```

### Tres detalles del nodo de Telegram que cuestan una ejecución fallida cada uno

**`sendDocument` vive bajo el recurso `message`, no `file`.** El recurso `file` solo expone `get` (descargar un fichero recibido). Con `resource: file` n8n compone una ruta que no existe en la API y Telegram responde **404 "The resource you are requesting could not be found"**, un error genérico que no apunta a la causa.

**`appendAttribution` vale `true` por defecto**, en `sendMessage` y en `sendDocument`. Sin desactivarlo, cada mensaje lleva colgado *"This message was sent automatically with n8n"* y el adjunto lo lleva como pie.

**El nodo de Telegram sustituye el item por la respuesta de su API.** Después de `Send Header` el HTML ya no está en `$json`, de ahí `Restore Payload` — el mismo patrón que `Return New Articles` en 03 y `Return Categorized Clusters` en 07. Y `Convert Briefing to File` deja el `json` **vacío**, solo con el binario, así que los dos nodos posteriores leen el destinatario con `$('Build Telegram Payload').first().json.chat_id` en vez de `$json`.

Los tres se resolvieron leyendo la descripción del nodo dentro del contenedor en vez de la documentación:

```bash
docker exec news-briefing-ai-n8n-1 node -e "
const {Telegram}=require('.../Telegram.node.js');
new Telegram().description.properties.filter(p=>p.name==='operation')
  .forEach(p=>console.log(p.displayOptions.show.resource, p.options.map(o=>o.value)));"
```

## Validación

Ejecución real del 7 de agosto de 2026, con la cadena completa `00 → 05 → 07 → 08 → 09`:

- 30 análisis, **0 fallos**, briefing de 30 acontecimientos y 55.035 bytes entregado en Telegram: cabecera, adjunto y despedida.
- La cadena entera tardó **11 minutos**; 09 tardó **1 segundo**.
- El `chat_id` se resolvió desde `app_config` con el contenedor **ya recreado sin** `TELEGRAM_CHAT_ID` en el entorno, así que la independencia de `$env` está comprobada, no supuesta.

## Mejora futura

- **La rama `Nothing to Deliver` no se ha ejercitado.** Requiere un día sin briefing, que solo ocurre si 05 y 07 no producen nada categorizado.
- **No hay reintento.** Si Telegram falla, el briefing queda en la tabla y no se reenvía: la fase no es idempotente hacia atrás. Reejecutar 09 a mano lo resuelve, y como lee de `briefings` no cuesta ni un token.
- **Un único destinatario.** `app_config` admite más filas sin cambiar el esquema, pero el workflow envía a uno.
- **El canal web sigue siendo la opción correcta a medio plazo**, si el pipeline deja de vivir en un portátil que se suspende. El `payload` de 08 está guardado precisamente para poder renderizar a otro formato sin reanalizar.
