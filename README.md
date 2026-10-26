# Finanças By Anderson — versão online (GitHub Pages + Supabase)

Esta é a evolução do seu app de finanças (arquivo único) para publicação na
internet, com **cadastro/login**, **sincronização em nuvem** e
**compartilhamento real entre duas contas** — preservando o visual (tema
escuro/dourado), a lógica e a área “Casal”.

> O design e as funcionalidades existentes foram mantidos. O que mudou foi a
> camada de dados: antes tudo ficava só no `localStorage` do aparelho; agora
> cada pessoa tem sua conta e seus dados ficam no Supabase, protegidos por
> linha (RLS) — não apenas por filtro de JavaScript.

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `index.html` | O app completo (abra/porím publique este arquivo). |
| `config.js` | URL e chave `anon` do seu projeto Supabase. **Edite este.** |
| `config.example.js` | Modelo de `config.js`. |
| `supabase/schema.sql` | Tabelas, RLS e funções. Rode no SQL Editor do Supabase. |
| `.gitignore` | Observações sobre o que versionar. |

---

## 1) Criar o projeto no Supabase

1. Acesse <https://supabase.com> e crie um projeto (plano gratuito serve).
2. No menu **SQL Editor**, clique em **New query**, cole TODO o conteúdo de
   `supabase/schema.sql` e clique em **Run**. Isso cria as tabelas, ativa o
   RLS e cria as funções de compartilhamento.
3. Em **Project Settings → API**, copie:
   - **Project URL** → vai em `SUPABASE_URL`
   - **anon public** → vai em `SUPABASE_ANON_KEY`
4. Em **Authentication → Providers → Email**, deixe o login por e-mail ativo.
   - Para testar rápido, você pode **desativar “Confirm email”** em
     *Authentication → Sign In / Providers → Email* (assim o login funciona
     sem precisar confirmar o e-mail). Em produção, mantenha ativado.
5. Em **Authentication → URL Configuration**, coloque em **Site URL** o
   endereço do seu GitHub Pages (ex.: `https://seu-usuario.github.io/financas/`)
   e adicione o mesmo endereço em **Redirect URLs** (necessário para o link de
   redefinição de senha voltar para o app).

## 2) Preencher o `config.js`

Abra `config.js` e substitua os valores de exemplo:

```js
window.SUPABASE_URL = 'https://SEU-PROJETO.supabase.co';
window.SUPABASE_ANON_KEY = 'ey...a_sua_chave_anon...';
```

> A chave **anon** é pública por natureza — pode ir para o repositório e para o
> navegador sem problema, porque quem protege os dados é o **RLS** do banco.
> **Nunca** use a chave **service_role** aqui: ela ignora o RLS.

## 3) Publicar no GitHub Pages

1. Crie um repositório no GitHub e envie estes arquivos (mantendo a pasta
   `supabase/`). Garanta que o `config.js` já preenchido foi enviado.
2. No repositório, vá em **Settings → Pages**.
3. Em **Source**, escolha **Deploy from a branch**, selecione a branch
   (`main`) e a pasta `/ (root)`. Salve.
4. Aguarde ~1 min. O site ficará em
   `https://seu-usuario.github.io/nome-do-repo/`.
5. Confirme que esse mesmo endereço está em **Site URL / Redirect URLs** no
   Supabase (passo 1.5).

> Dica: também funciona em qualquer hospedagem de arquivos estáticos
> (Netlify, Vercel, Cloudflare Pages). Não há build — são arquivos estáticos.

## 4) Migrar os dados que já existem no aparelho

Se você abrir o app pela primeira vez **no mesmo navegador** onde já usava a
versão antiga, ele detecta os dados salvos localmente e, logo após o primeiro
login, pergunta se você quer **importá-los para a sua conta**. Você também
pode fazer isso depois em **⚙︎ Conta → Dados deste dispositivo → Importar
agora**. A importação é sempre uma ação explícita sua — nada é enviado sem
confirmação.

---

## Como funciona o compartilhamento (máx. 2 contas)

- No botão **⚙︎ Conta** (topo), use **Enviar convite** e informe o e-mail da
  outra pessoa. O convite tem validade de 7 dias.
- A outra pessoa cria a conta com esse e-mail, abre **⚙︎ Conta** e clica em
  **Aceitar**. A partir daí, a conta dela aparece como a segunda conta do
  casal (botão de troca de conta e aba **Casal**).
- Os dados do parceiro aparecem **somente leitura** (o botão “+” fica oculto
  ao visualizar a conta do parceiro). Cada um edita apenas os próprios dados.
- **Encerrar compartilhamento** (qualquer um dos dois) remove o vínculo e o
  acesso aos dados do outro imediatamente.
- Regras garantidas **no banco** (RPCs `security definer`, transacionais):
  aceite atômico com trava de linha, limite rígido de 2 contas, um convite
  pendente por vez, e ninguém pode participar de dois compartilhamentos.

## Segurança (resumo)

- **RLS ativo em todas as tabelas.** As políticas de escrita exigem
  `user_id = auth.uid()`, então é impossível gravar na linha de outra pessoa
  ou “forjar o dono” de um registro para acessar o alheio.
- Leitura do parceiro só é liberada quando existe um compartilhamento aceito
  (verificado por função no próprio banco, não por JavaScript).
- A busca de usuário por e-mail (no convite) é feita por função
  `security definer` e **não** expõe dados de terceiros — retorna apenas se o
  convite foi registrado.
- No navegador usamos **somente a chave anon**. A `service_role` nunca aparece
  no frontend.

---

## Roteiro de testes

> Os itens marcados com ⚠️ dependem do **seu** projeto Supabase + Pages estarem
> configurados (não foi possível executá-los aqui, pois exigem um projeto real).

1. **Config faltando** — com `config.js` ainda nos valores de exemplo, o app
   mostra “Configuração necessária”. ✔ (comportamento garantido no código)
2. **Cadastro** ⚠️ — criar conta com e-mail/senha; perfil é criado automaticamente.
3. **Login / logout** ⚠️ — entrar, recarregar (sessão persiste), sair.
4. **Reset de senha** ⚠️ — “Esqueci a senha” envia e-mail; o link abre o app em
   modo “Defina uma nova senha”.
5. **Primeiro acesso** ⚠️ — conta nova começa vazia (não herda dados do aparelho).
6. **Migração** ⚠️ — no navegador com dados antigos, aceitar a importação e ver os
   lançamentos aparecerem; recarregar e confirmar que foram para a nuvem.
7. **Persistência** ⚠️ — criar uma despesa, recarregar: continua lá. Abrir em
   outro navegador logado na mesma conta: aparece igual.
8. **Convite** ⚠️ — enviar convite para o e-mail da 2ª conta; ver “Aguardando
   aceite”; cancelar e reenviar.
9. **Aceite** ⚠️ — na 2ª conta, aceitar; a conta do parceiro aparece na troca de
   contas e na aba Casal.
10. **Somente leitura** ⚠️ — ao visualizar a conta do parceiro, o botão “+” some.
11. **Limite de 2** ⚠️ — uma 3ª conta não consegue entrar no mesmo compartilhamento.
12. **Encerrar** ⚠️ — encerrar remove o acesso; a aba Casal volta a oferecer
    convite.
13. **Validade** ⚠️ — um convite com mais de 7 dias é recusado como “expirado”.
14. **Mobile** — abrir no celular: layout escuro/dourado preservado e responsivo.

## Limitações / observações honestas

- Não foi possível criar um projeto Supabase nem testar os fluxos online deste
  lado — a sintaxe do JavaScript e do app foi validada, mas os testes 2–13
  dependem da sua configuração (passos 1–3).
- A sincronização “ao vivo” entre o casal (ver mudanças do outro sem recarregar)
  usa o Realtime do Supabase; se quiser isso, rode as duas últimas linhas
  (comentadas) do final do `schema.sql`. Sem elas, os dados do parceiro
  atualizam ao reabrir/recarregar.
- Os dados financeiros de cada pessoa são guardados num documento JSON por
  usuário (uma linha por conta), protegido por RLS. Isso preserva 100% da
  lógica atual do app. Uma futura normalização por tabela de lançamentos
  poderia ser feita depois, sem mudar a experiência.
