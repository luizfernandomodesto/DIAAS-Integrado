`timescale 1ns / 1ps

// Recebe 1 amostra, guarda no buffer e calcula o filtro sobre as ultimas
// NUMTAPS amostras, sem reiniciar o historico entre elas.
module controlador_fsm_streaming #(
    parameter int NUMTAPS = 127
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            dado_valido_32b,
    input  logic                            limpa_buffer,
    output logic                            limpa_buffer_mem,
    output logic                            habilita_escrita_buffer,
    output logic [$clog2(NUMTAPS)-1:0]      endereco_escrita_buffer,
    output logic [$clog2(NUMTAPS)-1:0]      endereco_leitura_buffer,
    output logic [$clog2(NUMTAPS)-1:0]      endereco_leitura_pesos,
    output logic                            habilita_mac,
    output logic                            limpa_mac,
    output logic                            resultado_pronto
);

    typedef enum logic [1:0] {
        RECEBE_AMOSTRA = 2'b00,
        CALCULA        = 2'b01,
        FINALIZA       = 2'b10
    } estado_t;

    estado_t estado_atual;

    // O MAC tem 2 estagios, entao o ultimo produto chega ao acumulador 2
    // ciclos depois. Sem esperar, resultado_pronto subiria sem o ultimo tap.
    localparam int CICLOS_DRENAGEM = 2;

    logic [$clog2(NUMTAPS)-1:0] ponteiro_escrita;      // nunca reseta entre amostras
    logic [$clog2(NUMTAPS)-1:0] ponteiro_mais_recente;  // onde a amostra nova ficou
    logic [$clog2(NUMTAPS)-1:0] contador_pesos;         // 0..NUMTAPS-1, indexa a ROM
    logic [1:0]                 contador_drenagem;
    logic                       habilita_leitura;
    logic                       habilita_leitura_anterior;
    logic                       primeiro_ciclo_leitura;

    // Borda de subida de habilita_leitura: diz quando limpar o acumulador
    assign primeiro_ciclo_leitura = habilita_leitura && !habilita_leitura_anterior;

    assign endereco_leitura_pesos = contador_pesos;

    // Anda pra tras a partir da amostra mais nova: h[0] multiplica a mais
    // recente, h[NUMTAPS-1] a mais antiga.
    assign endereco_leitura_buffer =
        (ponteiro_mais_recente >= contador_pesos)
            ? (ponteiro_mais_recente - contador_pesos)
            : (ponteiro_mais_recente + NUMTAPS[$clog2(NUMTAPS)-1:0] - contador_pesos);

    logic fim_calculo;
    assign fim_calculo = (contador_pesos == NUMTAPS[$clog2(NUMTAPS)-1:0] - 1'b1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            estado_atual            <= RECEBE_AMOSTRA;
            ponteiro_escrita        <= '0;
            ponteiro_mais_recente   <= '0;
            habilita_escrita_buffer <= 1'b0;
            endereco_escrita_buffer <= '0;
            habilita_leitura          <= 1'b0;
            habilita_leitura_anterior <= 1'b0;
            habilita_mac              <= 1'b0;
            limpa_mac                 <= 1'b1;
            contador_pesos            <= '0;
            contador_drenagem         <= '0;
            limpa_buffer_mem          <= 1'b0;
            resultado_pronto          <= 1'b0;
        end else begin

            // 1 ciclo de atraso, pra dar tempo da memoria responder
            habilita_mac              <= habilita_leitura;

            // So no primeiro ciclo, senao carregaria resto da conta anterior
            limpa_mac                 <= primeiro_ciclo_leitura;
            habilita_leitura_anterior <= habilita_leitura;

            habilita_escrita_buffer <= 1'b0;
            habilita_leitura        <= 1'b0;
            resultado_pronto        <= 1'b0;
            limpa_buffer_mem        <= 1'b0;

            // So entre amostras, nunca no meio de um calculo
            if (limpa_buffer && estado_atual == RECEBE_AMOSTRA) begin
                limpa_buffer_mem      <= 1'b1;
                ponteiro_escrita      <= '0;
                ponteiro_mais_recente <= '0;
            end

            case (estado_atual)
                RECEBE_AMOSTRA: begin
                    contador_pesos    <= '0;
                    contador_drenagem <= '0;
                    if (dado_valido_32b) begin
                        // Escreve por cima da amostra mais antiga e avanca
                        habilita_escrita_buffer <= 1'b1;
                        endereco_escrita_buffer <= ponteiro_escrita;
                        ponteiro_mais_recente   <= ponteiro_escrita;
                        ponteiro_escrita        <= (ponteiro_escrita == NUMTAPS[$clog2(NUMTAPS)-1:0] - 1'b1)
                                                    ? '0 : ponteiro_escrita + 1'b1;
                        estado_atual            <= CALCULA;
                    end
                end

                CALCULA: begin
                    habilita_leitura <= 1'b1;
                    if (habilita_leitura) begin
                        if (fim_calculo) begin
                            estado_atual <= FINALIZA;
                        end else begin
                            contador_pesos <= contador_pesos + 1'b1;
                        end
                    end
                end

                FINALIZA: begin
                    // Espera o ultimo produto chegar ao acumulador
                    if (contador_drenagem == CICLOS_DRENAGEM[1:0]) begin
                        resultado_pronto <= 1'b1;
                        estado_atual     <= RECEBE_AMOSTRA;
                    end else begin
                        contador_drenagem <= contador_drenagem + 1'b1;
                    end
                end

                default: estado_atual <= RECEBE_AMOSTRA;
            endcase
        end
    end

endmodule
