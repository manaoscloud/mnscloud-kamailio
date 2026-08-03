# Kamailio Softswitch

Este diretório documenta o uso do Kamailio como camada Softswitch/SIP edge do mnscloud.

Para WebRTC/SIP over WebSocket e certificados WSS por domínio, use o conector
dedicado `mnscloud-kamailio-webrtc`. RTP/SRTP e rtpengine pertencem ao módulo
autônomo `mnscloud-media`, que pode ser consumido por WebRTC, Softswitch, SBC e
outros serviços que precisem ancorar mídia.

## Modelo

- O servidor físico mantém a URL base da API em `/etc/mnscloud/softswitch/api.base`.
- O servidor físico mantém UUID local em `/etc/mnscloud/softswitch/node.uuid`.
- O servidor físico mantém token local em `/etc/mnscloud/softswitch/api.token`.
- Esse UUID é vinculado ao cadastro `VoipSoftswitchServer.VsrNodeUUID`.
- O hash do token é salvo em `VoipSoftswitchServer.VsrApiTokenHash`.
- Cada requisição runtime enviada ao mnscloud usa `engine`, `node_uuid` e
  `Authorization: Bearer <token>` para validar o servidor.
- A API usa cache curto para a identidade do servidor, reduzindo IO por chamada sem perder revogação operacional.

## Cadastros

- `VoipSoftswitchProvider`: catálogo do provider/plataforma, com engines `kamailio`, `opensips`, `sippulse`, `vsc` e `custom`.
- `VoipSoftswitchServer`: servidores autorizados a consultar runtime.
- `RealtimeMediaServer`: media relay opcional selecionado no `VoipSoftswitchServer` para ancorar
  RTP/SRTP via `mnscloud-media`/`rtpengine`.
- `VoipSoftswitchAccount`: vínculo tenant, cliente, domínio e servidor usado para autorizar domínios e assinantes.

## Diagnóstico de assinantes

O status de registro é consultado pelo Agent associado ao servidor, nunca pelo navegador. A API cria
um job tipado e auditável para um assinante ou para a conta inteira. No host, o comando local
`kamailio-subscriber-runtime-status.sh` recebe uma lista limitada de identidades e consulta apenas
o registro local. `kamailio-trunk-runtime-status.sh` segue o mesmo contrato via Agent para trunks
em modo `register`; trunks `ip_acl`/`none` retornam `not_applicable`. OpenSIPS permanece fail-closed.
`kamcmd ul.lookup location sip:<usuario>@<dominio>`. O retorno contém presença e contato registrado,
sem senha SIP, token da API ou capacidade de executar comandos arbitrários.

## Endpoints Runtime

Os endpoints internos ficam em:

- `POST /api/v1/softswitch/runtime/heartbeat`
- `POST /api/v1/softswitch/runtime/bootstrap`
- `POST /api/v1/softswitch/runtime/registrations`
- `POST /api/v1/softswitch/runtime/auth`
- `POST /api/v1/softswitch/runtime/route`
- `POST /api/v1/softswitch/runtime/accounting`

O `engine` deve ser enviado como `kamailio` via body, query string ou header
`X-Softswitch-Engine`. O `node_uuid` pode ir via query string ou header
`X-Softswitch-Node-UUID`. O token é gerado pelo instalador, enviado como
`Authorization: Bearer <token>` no bootstrap e nas consultas runtime, e somente o
hash fica salvo no banco.

## Instalação

Antes de instalar, confirme:

- o API/control plane já está publicado com o contrato canônico `/api/v1/softswitch/runtime/*`;
- o `mnscloud-agent` já está instalado, enrolado e ativo; o instalador valida isso com
  `/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh --require-active --require-enrolled`;
- o canal `stable` do repositório aponta para uma versão que usa esse contrato;
- existe cadastro `VoipSoftswitchServer` para este runtime com engine `kamailio` e `VsrNodeUUID`
  compatível, ou o fluxo operacional de bootstrap está preparado para vincular o node UUID local;
- se este Softswitch deve ancorar RTP/SRTP, existe `RealtimeMediaServer` ativo selecionado no
  cadastro do `VoipSoftswitchServer`;
- o host consegue acessar a URL base da API;
- as portas SIP necessárias estão liberadas no firewall do host, normalmente `5060/udp` e
  `5060/tcp`.

Execute:

```bash
sudo bash scripts/install-kamailio-softswitch.sh
```

Para pré-visualizar sem aplicar mudanças:

```bash
sudo bash scripts/install-kamailio-softswitch.sh --dry-run
```

O instalador:

- aceita `MNSCLOUD_API_BASE`, `MNSCLOUD_SOFTSWITCH_NODE_UUID` e
  `MNSCLOUD_SOFTSWITCH_API_TOKEN` quando executado a partir do comando gerado pelo painel;
- solicita a URL base da API na primeira execução e salva em `/etc/mnscloud/softswitch/api.base`;
- configura o repositório oficial Kamailio 6.1.x antes da instalação;
  - Debian 12/13: `http://deb.kamailio.org/kamailio61` com keyring `/usr/share/keyrings/kamailio.gpg`;
  - Debian usa pinning em `/etc/apt/preferences.d/kamailio` para preferir os pacotes 6.1.x oficiais em vez dos pacotes antigos da distribuição;
  - Rocky 8/9: `https://rpm.kamailio.org/rocky/<major>/6.1/6.1/<arch>/`;
- instala Kamailio e ferramentas de troubleshooting (`sngrep`, `tcpdump`, `ngrep`, `ping`, `mtr`, `jq`, etc.);
- cria ou reaproveita `/etc/mnscloud/softswitch/node.uuid`;
- cria ou reaproveita `/etc/mnscloud/softswitch/api.token`;
- tenta vincular o node UUID via API bootstrap usando hostname, IPv4 privado e IPv4 público descoberto;
- salva `/etc/mnscloud/softswitch/media.socket` quando a API retorna o `rtpengineSocket` do
  `RealtimeMediaServer` selecionado;
- não executa SQL direto nem instala cliente MariaDB para vincular o node UUID;
- faz backup do `/etc/kamailio/kamailio.cfg` original como `.bkp`;
- gera um `kamailio.cfg` com autenticação SIP digest para REGISTER e INVITE de assinantes;
- habilita `rtpengine` no `kamailio.cfg` quando existe media relay selecionado; sem media relay, o
  conector continua atuando somente como sinalização/proxy SIP;
- salva contatos com `registrar/usrloc` em memória local;
- consulta `/route` na API para chamadas de saída quando o destino não está registrado localmente.
- grava o Bearer token local no `kamailio.cfg` para autenticar as chamadas runtime contra a API.

O arquivo gerado usa `http_client` para chamadas runtime síncronas de baixa latência contra a API.
REGISTER e INVITE de assinantes são fail-closed: se a API não autorizar ou se o digest SIP falhar, a
requisição é negada. Chamadas locais usam `lookup("location")`; chamadas de saída usam o contrato
`/api/v1/softswitch/runtime/route`.

Inbound por trunk/IP também usa `/api/v1/softswitch/runtime/route`, com `direction=inbound`,
`sourceIP` e DID discado. A API só devolve rota quando:

- o trunk vinculado ao softswitch tem `trustedCidrs` preenchido;
- o `sourceIP` do pacote SIP está dentro de um dos CIDRs/IPs permitidos;
- existe DID ativo para o número discado;
- o DID aponta para assinante registrado ou para destino externo explícito.

Sem esses requisitos, o conector continua fail-closed e não aceita a chamada inbound como trunk.

## Registros de tronco

Troncos com autenticação `register` são registros UAC de saída para operadoras. A API mantém a
configuração canônica; o Agent do servidor recebe o job `voip.softswitch.runtime` e executa
`scripts/sync-kamailio-softswitch-runtime.sh`. O script consulta `/runtime/registrations`, aplica
somente o delta pelo módulo UAC do Kamailio e remove explicitamente registros que deixaram de
existir no controle de plano. Não há polling periódico ou fallback local para essa configuração.

Troncos `ip_acl` não executam REGISTER: eles são identificados exclusivamente pelos IPs/CIDRs
autorizados durante a decisão inbound da API.

## Lifecycle

Validação:

```bash
sudo bash scripts/validate-kamailio-softswitch.sh
sudo kamailio -c -f /etc/kamailio/kamailio.cfg
sudo systemctl status kamailio
```

Use este procedimento seguro em qualquer servidor instalado. Ele inspeciona as alterações locais
do Git. Quando elas existirem somente nos scripts de lifecycle gerenciados, cria um backup auditável
em `/var/backups/mnscloud/kamailio-softswitch/` e restaura apenas esses scripts a partir de
`origin/main` antes de resolver a versão `stable`. Qualquer alteração local fora dessa allowlist
continua bloqueando a atualização.

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud

if [ ! -d mnscloud-kamailio-softswitch/.git ]; then
  gh repo clone manaoscloud/mnscloud-kamailio-softswitch
fi

sudo bash -s -- /opt/mnscloud/mnscloud-kamailio-softswitch <<'RECOVERY'
set -Eeuo pipefail
repo="$1"
cd "$repo"
git fetch origin main --tags --prune

changed_paths="$(git diff --name-only; git diff --cached --name-only)"
unexpected_paths="$(printf '%s\n' "$changed_paths" | awk 'NF' | sort -u | grep -vE '^scripts/(update-kamailio-softswitch|update-latest-kamailio-softswitch|validate-kamailio-softswitch|rollback-kamailio-softswitch)\.sh$' || true)"
test -z "$unexpected_paths" || {
  printf 'Alterações locais não gerenciadas:\n%s\n' "$unexpected_paths" >&2
  exit 1
}

backup_dir="/var/backups/mnscloud/kamailio-softswitch/lifecycle-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0750 "$backup_dir/files"
printf '%s\n' "$changed_paths" | awk 'NF' | sort -u >"$backup_dir/changed-paths.txt"
git diff --binary >"$backup_dir/worktree.patch"
git diff --cached --binary >"$backup_dir/index.patch"
git checkout origin/main -- scripts/{update-kamailio-softswitch,update-latest-kamailio-softswitch,validate-kamailio-softswitch,rollback-kamailio-softswitch}.sh
chmod +x scripts/{update-kamailio-softswitch,update-latest-kamailio-softswitch,validate-kamailio-softswitch,rollback-kamailio-softswitch}.sh
RECOVERY

cd /opt/mnscloud/mnscloud-kamailio-softswitch
sudo bash scripts/update-latest-kamailio-softswitch.sh stable
sudo bash scripts/validate-kamailio-softswitch.sh
```

Depois desse primeiro update seguro, a atualização normal pelo canal publicado é:

```bash
sudo bash scripts/update-latest-kamailio-softswitch.sh stable
sudo bash scripts/validate-kamailio-softswitch.sh
```

Para uma versão, branch, tag ou commit específico, execute primeiro o bootstrap acima e então:

```bash
sudo bash scripts/update-kamailio-softswitch.sh --ref <git-ref>
sudo bash scripts/validate-kamailio-softswitch.sh
```

Os scripts de update fazem `git fetch`, checkout do ref de destino, reexecutam o instalador e rodam
o validador. O atualizador faz backup e restaura automaticamente apenas alterações nos scripts de
lifecycle gerenciados; qualquer outra alteração local no código continua bloqueando o processo. O
estado local em `/etc/mnscloud/softswitch` é reaproveitado. O validador aceita os
dois modos suportados pelo `http_client` do Kamailio 6.1 (`http_client_query` e
`http_client_request`), mas exige que os três callbacks runtime usem um único modo de forma
consistente e que as variáveis de resposta graváveis estejam entre aspas.

Rollback local do arquivo de configuração do Kamailio:

```bash
sudo bash scripts/rollback-kamailio-softswitch.sh
```

O rollback restaura `/etc/kamailio/kamailio.cfg.bkp`, valida o arquivo restaurado e reinicia o
`kamailio.service`. Ele não altera registros do API/control plane nem move o checkout Git para outra
versão.

## Troubleshooting

Comandos úteis:

```bash
kamailio -c -f /etc/kamailio/kamailio.cfg
systemctl status kamailio
journalctl -u kamailio -f
sngrep -d any port 5060
tcpdump -ni any udp port 5060
```

Para validar o endpoint:

```bash
NODE_UUID="$(tr -d '[:space:]' < /etc/mnscloud/softswitch/node.uuid)"
API_TOKEN="$(tr -d '[:space:]' < /etc/mnscloud/softswitch/api.token)"
API_BASE="$(tr -d '[:space:]' < /etc/mnscloud/softswitch/api.base)"
curl -sS -X POST "${API_BASE}/api/v1/softswitch/runtime/heartbeat?node_uuid=${NODE_UUID}&engine=kamailio" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "X-Softswitch-Engine: kamailio" \
  --data '{"engine":"kamailio","hostname":"softswitch-dev1"}'
```
