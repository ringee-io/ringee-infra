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
- **El workflow de deploy del repo de la app** (AWS-21, pendiente) construye las imágenes ARM64, las sube a ECR, corre `migrate` y actualiza los servicios. Terraform ignora la revisión que corre en `api`, `orchestrator` y `chatgpt-mcp`, así que un `apply` nunca deshace un deploy. Si Terraform cambia una variable o un tamaño, el cambio sale en el siguiente deploy.
- `temporal` y `temporal-ui` sí los despliega Terraform: subir la versión de Temporal es un `apply`, después de correr `temporal-schema`.

## Secretos

- `ringee/<env>/shared`, `/api`, `/orchestrator` y `/chatgpt-mcp`: las variables de Railway. Las escribe `scripts/railway-env.py`; Terraform crea el contenedor y nunca lee ni escribe el valor.
- `ringee/<env>/generated`: lo que crea este stack (contraseñas de los roles `ringee_app` y `temporal`, el token de Valkey y las URLs armadas con ellos). Está en el state, que por eso vive en un bucket privado, cifrado y con versiones.
- La contraseña maestra de RDS la guarda RDS en su propio secreto y la rota él. Solo la usa la tarea `db-bootstrap`; las apps nunca.
- **Staging lleva credenciales de prueba**: su propia cuenta de Telnyx, Stripe en modo test y Clerk de desarrollo. `railway-env.py` se niega a escribir fuera de producción.

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

Eso prueba que la configuración es coherente, no que AWS acepte cada valor. Lo confirma el primer `apply` en staging. Sin confirmar:

- La versión de Valkey (`8.0`): `aws elasticache describe-cache-engine-versions --engine valkey`.
- Las etiquetas `temporalio/server:1.29.7`, `temporalio/admin-tools:1.29.7` y `temporalio/ui:2.54.1`: `mirror-images.sh` falla si alguna no existe.
- La conexión de Temporal a RDS con `SQL_TLS_ENABLED=true` sin verificar el certificado, que viaja cifrada dentro de la VPC. Para verificarlo haría falta meter el bundle de la CA de RDS en la imagen.

Falta además: el workflow de deploy (AWS-21), la imagen ARM64 de `chatgpt-mcp` (AWS-10), las migraciones en git (AWS-09) y el runbook del corte (AWS-24, AWS-26).
