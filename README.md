# ringee-infra

Infraestructura de Ringee en AWS con Terraform. El plan completo, con costos y decisiones, está en `docs/product/PLAN_MIGRACION_AWS.md` del repo de la app. Los IDs `AWS-xx` vienen de ahí.

Este repo es **privado**. Nunca lo publiques ni copies nada de aquí al repo de la app, que es público.

## Qué hay

| Ruta                        | Qué es                                                                                                                                                                |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bootstrap/`                | Se aplica una vez por cuenta: bucket de estado, OIDC de GitHub y los roles `github-terraform-plan`, `github-terraform-apply` y `github-deploy` (AWS-12, AWS-22).      |
| `envs/prod`, `envs/staging` | Las dos raíces. Solo cambian tamaños y opciones; todo lo demás está en `modules/stack`.                                                                               |
| `modules/stack`             | El entorno completo: red, RDS, Valkey, ALB, ECS, secretos, alarmas y horario de staging.                                                                              |
| `modules/*`                 | Las piezas: `network`, `security` (la matriz de acceso de §4.3), `ecr`, `rds`, `valkey`, `alb`, `ecs-cluster`, `ecs-service`, `secrets`, `observability`, `schedule`. |
| `config/secret-keys.json`   | **Solo nombres** de las variables copiadas de Railway, por ámbito. Lo genera `scripts/railway-env.py`.                                                                |
| `scripts/`                  | `railway-env.py` (AWS-18), `run-task.sh`, `mirror-images.sh` y `staging-power.sh`.                                                                                    |

Decidido el 4 de noviembre de 2026: **nivel B** (RDS Multi-AZ y 2 tareas de API) con **un solo nodo de Valkey**, y **sin réplicas de lectura**. Staging durante al menos 6 meses, encendido de lunes a viernes de 08:00 a 22:00 (hora de RD).

## Cómo se reparte el trabajo

- **Terraform** crea la infraestructura y la primera revisión de cada tarea.
- **El workflow de deploy del repo de la app** (AWS-21, ver CI/CD) construye las imágenes ARM64, las sube a ECR, corre `migrate` y actualiza los servicios. Terraform ignora la revisión que corre en `api`, `orchestrator` y `chatgpt-mcp`, así que un `apply` nunca deshace un deploy. Si Terraform cambia una variable o un tamaño, el cambio sale en el siguiente deploy.
- `temporal` y `temporal-ui` sí los despliega Terraform: subir la versión de Temporal es un `apply`, después de correr `temporal-schema`.

## Secretos

- `ringee/<env>/shared`, `/api`, `/orchestrator` y `/chatgpt-mcp`: las variables de Railway. Las escribe `scripts/railway-env.py`; Terraform crea el contenedor y nunca lee ni escribe el valor.
- `ringee/<env>/generated`: lo que crea este stack (contraseñas de los roles `ringee_app` y `temporal`, el token de Valkey y las URLs armadas con ellos). Está en el state, que por eso vive en un bucket privado, cifrado y con versiones.
- La contraseña maestra de RDS la guarda RDS en su propio secreto y la rota él. Solo la usa la tarea `db-bootstrap`; las apps nunca.
- **Staging nunca lleva credenciales de producción.** Desde el 4 de noviembre de 2026 arranca con valores falsos para Clerk, Resend y los demás servicios de terceros: la infraestructura y la configuración son reales, pero no hay login, llamadas, correos ni IA. Las de prueba vendrán después: su propia cuenta de Telnyx, Stripe en modo test y un Clerk solo para staging, ni el de prod ni el que se usa en local, porque el `privateMetadata.userId` de cada usuario de Clerk apunta a una sola base y la API lo reescribe en el primer login. `railway-env.py` se niega a escribir fuera de producción.

## Orden de arranque

Requisitos: AWS-03 hecho (Organizations, `ringee-prod` y `ringee-staging`, IAM Identity Center), `aws configure sso` con un perfil por cuenta, y Terraform 1.10 o más nuevo. Cada paso se hace primero en staging.

1. **Bootstrap**, una vez por cuenta, en el workspace del mismo nombre:

   ```bash
   cd bootstrap
   terraform init
   terraform workspace new staging    # o: terraform workspace select staging
   AWS_PROFILE=ringee-staging terraform apply -var-file=staging.tfvars
   terraform workspace new prod
   AWS_PROFILE=ringee-prod terraform apply -var-file=prod.tfvars
   ```

   Su state queda en `terraform.tfstate.d/<env>/` (fuera de git). Guarda una copia en el bucket de esa cuenta después de cada apply:

   ```bash
   AWS_PROFILE=ringee-prod aws s3 cp terraform.tfstate.d/prod/terraform.tfstate s3://ringee-tfstate-405762675020/bootstrap/terraform.tfstate
   ```

2. **Backend del entorno:** copia `envs/prod/backend.hcl.example` a `backend.hcl` con el ID de la cuenta y corre `terraform init -backend-config=backend.hcl`.

3. **Certificado:** el listener HTTPS espera a que ACM emita el certificado, así que primero se crea solo el certificado:

   ```bash
   terraform apply -target=module.stack.module.alb.aws_acm_certificate.this
   terraform output -json stack | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["certificate_validation_records"], indent=2))'
   ```

   Crea esos CNAME en Cloudflare **solo DNS (nube gris)** y espera a que ACM diga _Issued_ (unos minutos).

4. **Todo lo demás**, con los servicios en 0 tareas (`running = false`, el valor por defecto):

   ```bash
   terraform apply
   ```

5. **Imágenes de terceros** en ECR (Temporal y el cliente de PostgreSQL):

   ```bash
   AWS_PROFILE=ringee-prod scripts/mirror-images.sh prod
   ```

6. **Variables de Railway** (solo prod). Primero en seco, después de verdad, y otra vez justo antes del corte:

   ```bash
   scripts/railway-env.py
   AWS_PROFILE=ringee-prod scripts/railway-env.py --apply --expect-account <ID de ringee-prod>
   terraform apply        # si cambió config/secret-keys.json
   ```

7. **Bases de datos y Temporal:**

   ```bash
   scripts/run-task.sh prod db-bootstrap       # roles y las tres bases
   scripts/run-task.sh prod temporal-schema    # esquemas de Temporal
   ```

8. **Imágenes de la app:** el primer deploy del workflow (AWS-21) o un push manual de `ringee/api`, `ringee/orchestrator` y `ringee/chatgpt-mcp` construidas para `linux/arm64`.

9. **Encender** (en prod, la noche del corte, §10 paso 10). Primero solo Temporal, para que el namespace exista antes de que arranque el worker:
   ```bash
   aws application-autoscaling register-scalable-target --service-namespace ecs \
     --scalable-dimension ecs:service:DesiredCount --resource-id service/ringee-prod/temporal \
     --min-capacity 1 --max-capacity 1
   scripts/run-task.sh prod temporal-namespace   # reintenta hasta que el servidor responde
   ```
   Después, `running = true` en `terraform.tfvars` y `terraform apply`. Ese mismo apply crea las alarmas. Si el runbook pide `orchestrator` en 0 un rato más, bájalo igual que arriba.

Hasta que AWS-06 (SSE por Redis) corra estable en Railway, deja `api_min_tasks = 1`.

## Levantar staging

Todo con `AWS_PROFILE=ringee-staging`, desde la raíz del repo salvo que se diga otra cosa.

1. **Certificado** (en `envs/staging`): `terraform apply -target=module.stack.module.alb.aws_acm_certificate.this`. Crea en Cloudflare, en gris (solo DNS), los CNAME que muestra `aws acm describe-certificate`, y espera a que diga _Issued_.
2. **Todo lo demás** (en `envs/staging`): `terraform apply`, con los servicios en 0 tareas. RDS y Valkey tardan unos 15 minutos.
3. **DNS:** en Cloudflare, `api.staging.ringee.io` y `chatgpt.staging.ringee.io` como CNAME al balanceador (`terraform output -json stack`, campo `alb_dns_name`), en gris.
4. **Imágenes de terceros:** `scripts/mirror-images.sh staging` (necesita `crane`).
5. **Secretos:** `scripts/staging-env.py template` escribe `staging.env`, fuera de git. Ahí ya está copiada de prod la configuración que no es secreta, las URLs apuntan a staging y hay un `APP_ENCRYPTION_SECRET` nuevo. Rellena las credenciales de prueba (como mínimo las marcadas REQUIRED) y corre `scripts/staging-env.py load --expect-account 699340623836`. `load` rechaza cualquier valor igual al de producción, salvo la configuración que no identifica una cuenta (números, flags, nombres de modelo o un `*`). Guarda el archivo, o al menos su `APP_ENCRYPTION_SECRET`, en tu gestor de contraseñas: un `template` nuevo genera otra clave y lo cifrado en staging dejaría de leerse.
   - Desde el 2026-11-04 hay credenciales de prueba reales en Clerk, Telnyx, Resend (una clave solo de envío), Stripe (modo test) y WhatsApp. Clerk es la app `Ringee - STG` (instancia de desarrollo), con la configuración de autenticación de producción y su webhook a `/api/webhooks/clerk`. Las demás de terceros siguen falsas pero con formato válido, marcadas `DUMMY` en su comentario: OpenAI, Anthropic, Deepgram, R2, el webhook de Stripe y las apps OAuth. Sus secretos de firma son aleatorios y sus URLs usan `.invalid`.
   - **Telnyx comparte la cuenta de producción** (decidido el 2026-11-04), con recursos propios y webhooks a `api.staging.ringee.io`: la app de Call Control `Ringee Staging`, la credencial `Ringee SIP - Staging`, el perfil de salida `Ringee Staging Profile` (tope de 10 USD al día) y el de mensajería `Ringee Staging MSG` (5 USD al día). Por eso `load` acepta que `TELNYX_PUBLIC_KEY` y `RINGEE_PUBLIC_CALLER_ID` sean iguales a los de producción. Lo que staging haga en Telnyx, como comprar números o crear las conexiones de los desk phones, pasa en la cuenta de producción.
   - Para cambiar una credencial: edítala en `staging.env`, vuelve a correr `load` y reinicia el servicio con `aws ecs update-service --cluster ringee-staging --service <servicio> --force-new-deployment`. Las tareas leen los secretos al arrancar.
6. **Bases:** `scripts/run-task.sh staging db-bootstrap` y `scripts/run-task.sh staging temporal-schema`.
7. **Esquema de la app:** `scripts/staging-schema.py --expect-account 699340623836` copia la estructura de producción, sin datos, hasta que las migraciones estén en git (AWS-09). Lee producción con la URL pública de Railway, y su contraseña nunca sale de tu máquina.
8. **Imágenes de la app:** en GitHub, _Actions → Deploy app → Run workflow_, eligiendo _Use workflow from: staging_. Construye `ringee-app` en su branch `staging` y registra las revisiones; los servicios siguen en 0. Para probar otro branch, ponlo en `app_ref`: mientras AWS-06, AWS-07 y AWS-33 no lleguen a `staging`, es `feat/aws-migration-prep`.
9. **Encender:**
   - Primero Temporal: `aws application-autoscaling register-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount --resource-id service/ringee-staging/temporal --min-capacity 1 --max-capacity 1`.
   - Luego `scripts/run-task.sh staging temporal-namespace`.
   - Al final, `running = true` en `envs/staging/terraform.tfvars` y `terraform apply`.
10. **Comprobar:** `curl https://api.staging.ringee.io/api/health`. Staging se apaga los días laborables a las 22:00 y se enciende a las 08:00 (hora de RD); fuera de ese horario, `scripts/staging-power.sh on`.
11. **Frontend y webhooks:** `staging.ringee.io` en Vercel, en el branch `staging`, y los webhooks de prueba hacia `https://api.staging.ringee.io`: Clerk en `/api/webhooks/clerk`, Stripe en `/api/stripe/webhook`, y Telnyx en `/api/call/webhook` (failover `/api/call/webhook/failover`) y `/api/messaging/webhook`.

Después del primer apply, `TF_APPLY_ENVIRONMENTS=staging` deja que el CI aplique los cambios de este repo en cada push a `staging`.

## CI/CD

- **App → AWS** (`.github/workflows/deploy-aws.yml` en `ringee-app`): un push a `staging` despliega en la cuenta de staging y uno a `main` en la de prod, después de tu aprobación. Construye las imágenes en ARM64, las sube a ECR, corre `migrate` cuando `RUN_MIGRATIONS` es `true` (AWS-09), actualiza los servicios y hace un smoke test. Usa el rol `github-deploy`.
- **Este repo** (`.github/workflows/terraform.yml`): `fmt`, `terraform test` y `plan` en cada PR y en cada push a `staging` o `main`, con el rol de solo lectura `github-terraform-plan`. En un push, si `TF_APPLY_ENVIRONMENTS` incluye ese entorno, aplica con `github-terraform-apply` bajo las reglas del entorno de GitHub: `staging` sin revisor y `production` con tu aprobación. El job de apply vuelve a planificar y se detiene si el resumen no coincide con el que revisaste. No sube el plan como artefacto, porque en un repo público cualquiera puede descargarlo y el plan guarda los secretos generados.
- **El primer apply de cada entorno se hace desde tu Mac**, empezando por el certificado (ver "Orden de arranque"):
  ```bash
  cd envs/staging
  AWS_PROFILE=ringee-staging terraform init -backend-config=backend.hcl
  AWS_PROFILE=ringee-staging terraform apply
  ```

Los dos repos son públicos. Eso es lo que permite, con GitHub Free, que los entornos exijan branch y revisor. Los PRs de forks no reciben secretos ni tokens OIDC.

En `ringee-app` (_Settings → Environments_):

| Entorno      | Branches que acepta | Revisor                                   | Variables                                                                                                                                |
| ------------ | ------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `staging`    | `staging`           | ninguno                                   | `AWS_DEPLOY_ROLE_ARN` = `arn:aws:iam::699340623836:role/github-deploy`, `API_HOST` = `api.staging.ringee.io`, `RUN_MIGRATIONS` = `false` |
| `production` | `main`              | tú, con _Prevent self-review_ desactivado | `AWS_DEPLOY_ROLE_ARN` = `arn:aws:iam::405762675020:role/github-deploy`, `API_HOST` = `api.ringee.io`, `RUN_MIGRATIONS` = `false`         |

La variable de repositorio `AWS_DEPLOY_ENVIRONMENTS` decide quién despliega: sin definir, nadie; `staging` cuando el staging esté arriba; `staging,production` la semana del corte. Mientras tanto Railway sigue desplegando `main`.

En `ringee-infra` (_Settings → Environments_), sin variables:

| Entorno      | Branches que acepta | Revisor                                   |
| ------------ | ------------------- | ----------------------------------------- |
| `staging`    | `staging`           | ninguno                                   |
| `production` | `main`              | tú, con _Prevent self-review_ desactivado |

La variable de repositorio `TF_APPLY_ENVIRONMENTS` hace lo mismo para Terraform: sin definir, el CI solo planifica. Se define después del primer apply de cada entorno. Además, en _Settings → Actions → General_, elige _Require approval for all external contributors_ en los workflows de PRs de forks.

## Operación

- **Una tarea puntual:** `scripts/run-task.sh <env> ops -- sh -c 'psql "$PG_URL_APP" -c "select 1"'`.
- **Entrar a un contenedor:** `aws ecs execute-command --cluster ringee-prod --task <id> --container api --interactive --command sh`.
- **Temporal UI** (sin dominio público): sube `temporal-ui` a 1 tarea y abre un túnel de SSM.
  ```bash
  aws application-autoscaling register-scalable-target --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount --resource-id service/ringee-prod/temporal-ui \
    --min-capacity 1 --max-capacity 1
  # Con el ID de la tarea y el runtimeId del contenedor (aws ecs describe-tasks):
  aws ssm start-session --target ecs:ringee-prod_<taskId>_<runtimeId> \
    --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080
  ```
  Abre `http://localhost:8080` y vuelve a 0 al terminar.
- **Staging fuera de horario:** `AWS_PROFILE=ringee-staging scripts/staging-power.sh on` (y `off`). Un `terraform apply` de noche lo vuelve a encender hasta las 22:00 del día siguiente laborable.

## Comprobado y pendiente

Comprobado el 4 de noviembre de 2026, sin cuenta de AWS: `terraform validate` en las tres raíces y `terraform test` en `modules/stack`. El test aplica el stack completo contra proveedores simulados, en las variantes prod, parado y staging, y comprueba que las dos guardas de `config/secret-keys.json` frenan el plan. `scripts/railway-env.py` corrió en seco contra Railway.

**Staging en AWS, 4 de noviembre de 2026.** El primer `apply` real levantó el stack completo. Corrieron `db-bootstrap`, `temporal-schema` (`temporal` 1.18, `temporal_visibility` 1.9), `temporal-namespace` y `staging-schema.py` (133 tablas, sin datos). _Deploy app_ construyó el branch `staging` de ringee-app en ARM64, y con `running = true` la API responde `200` en `https://api.staging.ringee.io/api/health`. El orchestrator se conecta a Temporal y crea sus 15 schedules. Temporal habla con RDS por TLS (`SQL_TLS_ENABLED=true`), aunque sin comprobar el certificado: va cifrado dentro de la VPC, y verificarlo exigiría meter el bundle de la CA de RDS en la imagen.

Ese primer apply destapó lo que los proveedores simulados no ven, ya corregido:

- ECS rechaza un servicio cuyo target group todavía no usa ningún balanceador. Por eso `target_group_arns` espera a las reglas del listener, que a su vez esperan al certificado.
- RDS informa `rds.force_ssl` como `pending-reboot`, y service discovery no devuelve el bloque vacío `health_check_custom_config`. Sin los ajustes, cada plan mostraba cambios.
- El `ENTRYPOINT` de `temporalio/admin-tools` es `tini -- sleep infinity`, así que cualquier comando quedaba como argumento de `sleep`. `temporal-admin` fija `entry_point = ["tini", "--"]`.
- En una cuenta nueva, el primer `CreateReplicationGroup` puede fallar con `InvalidCredentialsException` mientras se propaga el rol de servicio de ElastiCache. Basta con reintentar.
- El formato del `sub` de los tokens OIDC de GitHub depende del repositorio. ringee-infra firma con IDs inmutables (`repo:ringee-io@262492135/ringee-infra@<id>:…`), y su forma simple se rechaza. ringee-app firma con la forma simple (`repo:ringee-io/ringee-app:…`), como mostró CloudTrail en el primer push a `staging`. `github-deploy` acepta las dos formas para ringee-app. El `sub` real aparece en el evento `AssumeRoleWithWebIdentity` de CloudTrail, en `userIdentity.userName`.

Falta: la imagen ARM64 de `chatgpt-mcp` (AWS-10, hoy pesa 1 GB), las migraciones en git (AWS-09), las credenciales de prueba de staging (hoy son falsas) y el runbook del corte (AWS-24, AWS-26).
