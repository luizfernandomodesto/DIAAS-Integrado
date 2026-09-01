`timescale 1ns / 1ps

module controlador_fsm (
    input  logic clk,
    input  logic rst_n,
    input  logic dado_valido_32b,
    input  logic fim_calculo,
    output logic habilita_escrita,
    output logic habilita_leitura,
    output logic habilita_mac,
    output logic limpa_mac
);

    typedef enum logic [1:0] {
        RECEBE_DADOS = 2'b00,
        CALCULA      = 2'b01,
        FINALIZA     = 2'b10
    } estado_t;

    estado_t estado_atual;
    logic [9:0] contador_dados;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            estado_atual     <= RECEBE_DADOS;
            habilita_escrita <= 1'b0;
            habilita_leitura <= 1'b0;
            habilita_mac     <= 1'b0;
            limpa_mac        <= 1'b1;
            contador_dados   <= 10'd0;
        end else begin

            habilita_mac <= habilita_leitura;

            habilita_escrita <= 1'b0;
            habilita_leitura <= 1'b0;

            case (estado_atual)

                RECEBE_DADOS: begin
                    limpa_mac <= 1'b1;

                    if (dado_valido_32b) begin
                        habilita_escrita <= 1'b1;
                        contador_dados   <= contador_dados + 10'd1;

                        if (contador_dados == 10'd1023) begin
                            estado_atual <= CALCULA;
                        end
                    end
                end

                CALCULA: begin

                    habilita_leitura <= 1'b1;
                    limpa_mac        <= ~habilita_leitura;

                    if (fim_calculo) begin
                        estado_atual <= FINALIZA;
                    end
                end

                FINALIZA: begin

                    estado_atual <= RECEBE_DADOS;
                end

                default: estado_atual <= RECEBE_DADOS;
            endcase
        end
    end

endmodule
