# 00 · Trigger / Orquestador

## Objetivo

Dar al pipeline un punto de entrada único y programado. Hasta esta fase, producir el material del briefing exigía acordarse de ejecutar `05-llm-analysis` y después `07-categorization` a mano, en ese orden — una carga operativa que en una tarea diaria acaba fallando.

## Arquitectura

### Por qué el encadenado vive aquí y no dentro de cada fase

Las fases 01–04 se llaman en cascada (cada una invoca a la anterior con `Execute Workflow`) porque cada una consume directamente la salida de la anterior. A partir de 05 ese patrón deja de aplicar: 05 y 07 se comunican por la tabla `cluster_analysis`, no por el valor de retorno (ver `docs/07-categorization.md`).

La tentación es hacer que 07 llame a 05 para garantizar datos frescos. Se descartó porque **destruye la independencia que hace útil a 07**: recategorizar los clusters existentes tras un ajuste del prompt cuesta hoy ~3.000 tokens y 5 segundos; si 07 arrastrara a 05, la misma operación implicaría una reingesta RSS completa (01→04) más el drenado de la cola de 05 con sus esperas de 20 segundos, gastando presupuesto del modelo caro solo para reetiquetar.

Orquestar desde 00 da las dos cosas: la corrida diaria automática siempre trabaja sobre datos frescos, y las ejecuciones manuales de 07 siguen siendo baratas e independientes.

### Un fallo de 05 no debe impedir que corra 07

La llamada a 05 usa `onError: continueErrorOutput`, y **ambas ramas —éxito y error— entran a 07**. Si Groq falla o 05 topa su tope diario, 07 debe categorizar igualmente lo que ya haya en la tabla; lo contrario dejaría análisis sin etiquetar hasta el día siguiente por un fallo ajeno. Se enruta por una rama de error explícita en vez de con `continueRegularOutput` para que el fallo quede visible en el canvas y en el log de la ejecución, no tragado en silencio.

Por el mismo motivo lleva `alwaysOutputData`: un día sin clusters nuevos haría que 05 devolviera 0 items y el encadenado se cortaría antes de llegar a 07.

`Call '07-categorization'` lleva `executeOnce` para que la convergencia de las dos ramas no pueda disparar la fase dos veces.

### Qué no orquesta

**06-quality-filter no está en la cadena.** Está pausado por decisión de producto mientras el esfuerzo va a la cobertura multi-fuente (ver `docs/06-quality-filter.md`); añadirlo aquí lo reactivaría de facto. Cuando se reanude, entra detrás de 07.

**08 y 09 tampoco**, porque todavía no existen. El orquestador crece por el final a medida que se cierran fases.

## Implementación

**Flujo de nodos:**
```
Schedule Trigger (cron 0 7 * * *)
  → Call '05-llm-analysis' (alwaysOutputData, continueErrorOutput)
      success ─┐
      error   ─┴→ Call '07-categorization' (executeOnce)
                    → Pipeline Complete (NoOp)
```

La hora (07:00) se interpreta en la zona horaria del contenedor de n8n, definida por `TIMEZONE` en `.env`.

**Duración esperada de una corrida**: la domina 05, que procesa 1 cluster por ejecución con 20 segundos de espera entre auto-llamadas. Con el tope diario de 25 análisis son unos 10 minutos. 07 añade segundos.

**Nota de n8n**: un workflow publicado no puede guardarse si referencia un sub-workflow sin publicar — el `PUT` se rechaza con `Cannot publish workflow: Node "X" references workflow Y which is not published`. Es la contrapartida de la regla ya conocida (un workflow solo puede auto-llamarse si está publicado): publicar propaga el requisito a toda la cadena. Por eso las ocho fases existentes están publicadas.

## Validación

Primera corrida real ejecutada de principio a fin. El cableado funciona: la rama de éxito de 05 alimenta a 07, y `executeOnce` evita que 07 se dispare más de una vez pese a recibir cientos de items de entrada.

Esa misma corrida destapó **un bug de diseño en el tope diario de 05** que solo podía aparecer al existir un trigger programado. 05 contaba sus análisis del día sobre una ventana deslizante de 24 horas; como el trabajo de aquel día se había hecho a las 09:22 y el cron dispara a las 07:00, la ventana seguía llena en el momento del disparo. Resultado: la corrida programada se saltaba el análisis con 20 clusters pendientes, y lo habría hecho todos los días siguientes — un bloqueo autoperpetuante. Corregido pasando el corte al día natural UTC, que además coincide con el reset real del presupuesto de Groq (ver `docs/05-llm-analysis.md`).

Es el tipo de fallo que no aparece ejecutando las fases a mano: solo se manifiesta cuando la hora de disparo es fija y el trabajo del día anterior cayó más tarde que esa hora.

Queda por observar en producción: una corrida en la que 05 llegue efectivamente a analizar (la primera topó el tope), y la ruta de error de la llamada a 05.

## Mejora futura

- Sin notificación de fallo: hoy una corrida fallida solo se ve entrando al historial de ejecuciones de n8n.
- Una única corrida diaria a las 07:00 significa que lo publicado durante el día no entra hasta la mañana siguiente. Aumentar la frecuencia depende de que la ventana de 24h de 04 y los topes diarios de 05 se recalibren juntos, no por separado.
- Cuando existan 08 y 09, valorar si el orquestador debe seguir siendo una cadena lineal o separar "producir material" de "ensamblar y entregar", para poder reconstruir un briefing sin repetir el análisis.
