# Build host - osobny state, świadomie tymczasowe rozwiązanie

Ten katalog to **osobny root module Terraform** (własny plik stanu, nie
współdzielony z `../terraform`). Tworzy jednorazową, wyrzucalną maszynę EC2
(Graviton/arm64), na której buduje się i testuje obraz Dockera z
`../runner-image/`, zanim trafi do S3 i dalej do `create-microvm-image`.

## Dlaczego osobny state, a nie jeden wspólny stack

- **Inny cykl życia.** Core stack (`../terraform`) jest długożyjący - S3,
  IAM, obraz MicroVM mają istnieć cały czas. Build host jest z definicji
  jednorazowy: powstaje, buduje, znika. Trzymanie ich w jednym state
  oznacza, że `terraform destroy` na buildzie ryzykuje przypadkowe dotknięcie
  długożyjącej infrastruktury (albo odwrotnie - zapomnisz zniszczyć maszynę,
  bo boisz się ruszyć resztę stacku).
- **Inny "blast radius".** Błąd w konfiguracji maszyny budującej (SG, IAM)
  nie powinien móc wywrócić planu/apply dla stacku, który trzyma
  produkcyjny obraz runnera.
- **Explicit > implicit.** Zamiast `terraform_remote_state` czytającego stan
  z `../terraform`, nazwa bucketu S3 jest przekazywana jawnie jako zmienna
  (`artifact_bucket_name`). To trochę więcej pisania, ale zero ukrytego
  sprzężenia między stackami - każdy z nich da się przenieść, zmienić
  backend albo usunąć niezależnie.

## To jest opcjonalna ścieżka, nie jedyna

Ten build host to najprostszy możliwy sposób, żeby zbudować obraz bez
instalowania Dockera lokalnie - nic więcej. Zakładamy, że z czasem to się
zmieni. Kilka wariantów, które mają sens w miarę dojrzewania procesu:

- Zamiast osobnej maszyny: CodeBuild / EC2 Image Builder z natywnym runnerem
  arm64, spięte z pipeline'em CI samego repo z obrazem runnera.
  build host jest najprostszym punktem startowym - świadomie wybranym, żeby
  najpierw sprawdzić, czy cała reszta (Terraform core stack, hook_server.py,
  rejestracja przez GitHub App) w ogóle działa, zanim zainwestujemy czas w
  docelowy, zahardenowany pipeline.

## Roadmapa hardeningu (ogół → szczegół)

Stan obecny (ten commit) jest świadomie minimalny. W kolejności, w jakiej
sensownie to zaostrzać:

1. **Egress przez prywatne artifactory zamiast publicznego internetu.**
   Dziś build host i sam obraz (patrz `../runner-image/Dockerfile`) ciągną
   pakiety z `github.com`, PyPI, publicznego `dnf`/AL2023 repo. Docelowo:
   wewnętrzne lustro (Artifactory/Nexus/ECR pull-through cache) + allowlist
   na poziomie sieci, żeby build w ogóle nie miał trasy do publicznego
   internetu.
2. **`associate_public_ip = false` + VPC endpoints.** Wymaga endpointów dla
   S3 i SSM (`com.amazonaws.<region>.s3`,
   `com.amazonaws.<region>.ssm`/`ssmmessages`/`ec2messages`) w subnecie -
   dopiero wtedy maszyna może być w pełni prywatna.
3. **SSM Session Manager zamiast SSH.** Już włączone domyślnie
   (`ssh_allowed_cidrs = []`) - `key_name`/SSH to dziś opt-in wyjątek, nie
   ścieżka domyślna.
4. **Skanowanie i podpisywanie obrazu.** SBOM (np. Syft) + skan podatności
   (Grype/Trivy) + podpis (cosign) obrazu przed uploadem do S3 - dziś
   `Dockerfile` trafia tam bez żadnej automatycznej weryfikacji.
5. **Pipeline zamiast ręcznego SSH/SSM.** Ostatecznie ten cały katalog
   powinien zniknąć na rzecz CI (np. innego runnera/GitHub-hosted) budującego
   i publikującego obraz automatycznie przy zmianie w `runner-image/`.

Nie robimy tego wszystkiego na raz celowo - najpierw kompletna, działająca
ścieżka end-to-end (ten build host), potem zaostrzanie punkt po punkcie.

## Użycie

```bash
cd build-host
cp example.tfvars terraform.tfvars   # uzupełnij artifact_bucket_name i subnet_id
terraform init
terraform apply
```

Połącz się (domyślnie tylko SSM, patrz `var.ssh_allowed_cidrs` jeśli
potrzebujesz SSH):

```bash
terraform output -raw ssm_session_command | bash
```

Na maszynie: `docker` i `git`/`zip` są już zainstalowane przez `user_data`.
Dalsze kroki (`docker build`, smoke test, `zip`, `aws s3 cp`) - patrz
`../README.md`, sekcja "Build obrazu na EC2".

## Sprzątanie

```bash
terraform destroy
```

To jedyny stack w tym repo, który powinieneś niszczyć rutynowo po każdym
buildzie - nic tu nie powinno żyć dłużej niż trwa budowanie obrazu.
