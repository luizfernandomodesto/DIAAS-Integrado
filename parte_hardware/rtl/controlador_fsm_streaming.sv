`timescale 1ns / 1ps

module controlador_fsm_streaming #(
    parameter int NUMTAPS = 127
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            dado_valido_32b,
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

    logic [$clog2(NUMTAPS)-1:0] ponteiro_escrita;
    logic [$clog2(NUMTAPS)-1:0] ponteiro_mais_recente;
    logic [$clog2(NUMTAPS)-1:0] contador_pesos;
    logic                       habilita_leitura;
    logic                       habilita_leitura_anterior;
    logic                       primeiro_ciclo_leitura;

    assign primeiro_ciclo_leitura = habilita_leitura && !habilita_leitura_anterior;

    assign endereco_leitura_pesos = contador_pesos;
    assign endereco_leitura_buffer =
        (ponteiro_mais_recente >= contador_pesos)
            ? (ponteiro_mais_recente - contador_pesos)
            : (ponteiro_mais_recente + NUMTAPS[$clog2(NUMTAPS)-1:0] - contador_pesos);

    logic fim_calculo;
    assign fim_calculo = (contador_pesos == NUMTAPS - 1);

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
            resultado_pronto          <= 1'b0;
        end else begin

            habilita_mac              <= habilita_leitura;

            limpa_mac                 <= primeiro_ciclo_leitura;
            habilita_leitura_anterior <= habilita_leitura;

            habilita_escrita_buffer <= 1'b0;
            habilita_leitura        <= 1'b0;
            resultado_pronto        <= 1'b0;

            case (estado_atual)
                RECEBE_AMOSTRA: begin
                    contador_pesos <= '0;
                    if (dado_valido_32b) begin
                        habilita_escrita_buffer <= 1'b1;
                        endereco_escrita_buffer <= ponteiro_escrita;
                        ponteiro_mais_recente   <= ponteiro_escrita;
                        ponteiro_escrita        <= (ponteiro_escrita == NUMTAPS - 1)
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
                    resultado_pronto <= 1'b1;
                    estado_atual     <= RECEBE_AMOSTRA;
                end

                default: estado_atual <= RECEBE_AMOSTRA;
            endcase
        end
    end

endmodule
