# 🔌 CableNet

<div align="center">

![CableNet](assets/banner.jpg)

### O monitor inteligente de conexão Ethernet e Wi-Fi na barra de menus do macOS

[![macOS](https://img.shields.io/badge/macOS-13.0+-blue?style=for-the-badge&logo=apple)](https://github.com/WennyLife/CableNet)
[![Arquitetura](https://img.shields.io/badge/Bin%C3%A1rio-Universal%20(Apple%20Silicon%20%2B%20Intel)-6f42c1?style=for-the-badge)](https://github.com/WennyLife/CableNet)
[![Linguagem](https://img.shields.io/badge/Swift-5.9+-F05138?style=for-the-badge&logo=swift)](https://github.com/WennyLife/CableNet)
[![Licença](https://img.shields.io/badge/Licen%C3%A7a-MIT-green?style=for-the-badge)](LICENSE)
[![Privacidade](https://img.shields.io/badge/Privacidade-100%25%20Local%20%26%20Zero%20Telemetria-00b4d8?style=for-the-badge)](https://github.com/WennyLife/CableNet)

<br/>

### 🚀 **Clique abaixo para baixar a versão mais recente:**

[![Download DMG](https://img.shields.io/badge/⬇️_Baixar_Instalador-CableNet_.dmg-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/WennyLife/CableNet/raw/main/release/CableNet-1.0.11.dmg)
&nbsp;
[![Download ZIP](https://img.shields.io/badge/📦_Baixar_Pacote-CableNet_.zip-0366d6?style=for-the-badge)](https://github.com/WennyLife/CableNet/raw/main/release/CableNet-1.0.11.zip)

<br/>

</div>

---

## 💡 O que é o CableNet?

O **CableNet** é um utilitário leve e minimalista criado exclusivamente para o ecossistema macOS. Ele vive silenciosamente na sua Barra de Menus e monitora em tempo real a interface de rede ativa do seu Mac.

Se você usa docks, adaptadores USB-C/Thunderbolt ou cabos RJ45 conectados ao seu Mac, frequentemente o macOS pode continuar usando o Wi-Fi sem que você perceba — ou vice-versa. Com o **CableNet**, basta um bater de olhos na barra superior para ter certeza de qual interface está transportando seus dados.

---

## ✨ Principais Funcionalidades

* 🌐 **Detecção Automática da Interface Ativa:**
  * **Cabo de Rede (RJ45):** Ícone RJ45 característico com indicador verde brilhante quando a rota principal for Ethernet.
  * **Wi-Fi:** Ícone de ondas de sinal ciano suave quando conectado à rede sem fio.
  * **Outras Conexões / Offline:** Ícone discreto em tom neutro/cinza quando desconectado ou em interfaces alternativas (ex.: VPN).
* 🩺 **Diagnóstico Ativo de Internet:**
  * Realiza checagens periódicas e ultraleves (a cada 90s) contra pontos de verificação de alta disponibilidade da Apple.
  * **Alerta Visual Imediato:** Ícone ou ponto vermelho caso a rede local esteja conectada mas sem acesso real à internet.
  * **Status de Verificação:** Ponto amarelo transitório durante o teste de resposta.
* ✨ **Animações Nativas & Respeito à Acessibilidade:**
  * Efeito sutil ao passar o cursor ou ao alternar interfaces (raios amarelos no conector RJ45 e ondas de sinal no Wi-Fi).
  * Sem pulos ou saltos na barra de menus: layout estável com geometria fixa.
  * Respeita integralmente a preferência de sistema **Reduzir Movimento** (*Reduce Motion*) do macOS.
  * Opção direta no menu para desativar animações a qualquer momento.
* 🚀 **Inicialização Opcional com o Sistema:**
  * Configure com um único clique no menu para abrir automaticamente ao ligar ou reiniciar o Mac (usando a API moderna `ServiceManagement`).
* 🔒 **Privacidade Absoluta (Zero Rastreamento):**
  * Sem anúncios, sem SDKs de terceiros, sem coleta de dados pessoais, identificadores de máquina ou histórico de tráfego.
  * App 100% autônomo e de código aberto.

---

## 📐 Como o CableNet Funciona

```mermaid
flowchart TD
    subgraph macOS["🍎 macOS SystemConfiguration & CoreWLAN"]
        Routing["Tabela de Rotas / Interface Primária"]
        NetEvent["SCDynamicStore (Eventos de Rede em Tempo Real)"]
    end

    subgraph CableNetApp["🔌 CableNet Menu Bar App"]
        Observer["Observador Nativo de Interface"]
        Probe["Diagnóstico Leve de Internet (a cada 90s)"]
        IconEngine["Renderizador Gráfico Procedural"]
    end

    subgraph MenuBar["🖥️ Barra de Menus do macOS"]
        RJ45["🟢 RJ45 Verde (Cabo Conectado + Internet)"]
        WiFi["🔵 Wi-Fi Ciano (Sem Fio + Internet)"]
        NoNet["🔴 Alerta Vermelho (Conectado mas Sem Internet)"]
    end

    NetEvent --> Observer
    Routing --> Observer
    Observer --> IconEngine
    Observer --> Probe
    Probe --> IconEngine

    IconEngine --> RJ45
    IconEngine --> WiFi
    IconEngine --> NoNet

    classDef apple fill:#0071e3,stroke:#fff,stroke-width:2px,color:#fff;
    classDef app fill:#1a2332,stroke:#00b4d8,stroke-width:2px,color:#fff;
    classDef status fill:#0b3c26,stroke:#2ecc71,stroke-width:2px,color:#fff;
    class macOS apple;
    class CableNetApp app;
    class MenuBar status;
```

---

## 🎨 Guia de Estados Visuais

| Ícone | Interface Ativa | Conexão com a Internet | Descrição |
|:---:|:---:|:---:|:---|
| 🟢 🔌 | **Ethernet (RJ45)** | ✅ Online | Conexão cabeada ativa com velocidade e estabilidade máxima. |
| 🟡 🔌 | **Ethernet (RJ45)** | ⏳ Testando | Validando conectividade externa com a internet. |
| 🔴 🔌 | **Ethernet (RJ45)** | ❌ Sem Internet | Cabo conectado à rede local, porém sem saída para a internet. |
| 🔵 📶 | **Wi-Fi** | ✅ Online | Tráfego roteado pela interface de rede sem fio. |
| 🔴 📶 | **Wi-Fi** | ❌ Sem Internet | Conectado ao roteador Wi-Fi, porém sem acesso externo. |
| ⚪ 🔌 | **Desconectado / Outra** | — | Nenhuma rota padrão identificada ou adaptador desconectado. |

---

## 📥 Instalação

1. Baixe a versão mais recente: **[`CableNet-1.0.11.dmg`](https://github.com/WennyLife/CableNet/raw/main/release/CableNet-1.0.11.dmg)**.
2. Dê um duplo clique no arquivo `.dmg` montado.
3. Arraste o ícone do **CableNet** para a pasta **Aplicativos** (`/Applications`).
4. Abra o **CableNet** via Spotlight (`Cmd + Espaço`) ou pelo Launchpad.
5. O ícone aparecerá imediatamente na sua **Barra de Menus** (canto superior direito perto do relógio).

> [!NOTE]
> Por ser um utilitário exclusivo de barra de menus (`LSUIElement = true`), o CableNet não polui o seu Dock nem abre janelas flutuantes desnecessárias.

---

## 🛠️ Compilação a partir do Código-Fonte

O CableNet foi desenvolvido inteiramente em **Swift nativo** e não requer o Xcode completo para ser compilado — apenas as ferramentas de linha de comando (`Command Line Tools`) da Apple.

### Clonar o repositório:
```bash
git clone https://github.com/WennyLife/CableNet.git
cd CableNet
```

### Compilar o pacote universal (arm64 + x86_64):
```bash
bash src/build.sh
```

O script gerará automaticamente:
* Binário universal para Apple Silicon (M1/M2/M3/M4) e processadores Intel.
* Geração procedural dos ícones em todas as resoluções (`.icns` e `.iconset`).
* Criação da estrutura de pacote `CableNet.app`.
* Assinatura ad-hoc de runtime do macOS.

---

## 💻 Requisitos de Sistema

* **macOS:** 13.0 (Ventura) ou superior (macOS Sonoma, macOS Sequoia testados).
* **Processador:** Apple Silicon (M1, M2, M3, M4) ou Intel 64-bit.
* **Permissões:** Nenhuma permissão especial de acessibilidade ou kernel extension é necessária.

---

## 📄 Licença

Este projeto é distribuído sob os termos da licença **MIT**. Consulte o arquivo [LICENSE](LICENSE) para mais detalhes.

---

<div align="center">
Desenvolvido com carinho por <a href="https://github.com/WennyLife"><strong>WennyLife</strong></a>
</div>
