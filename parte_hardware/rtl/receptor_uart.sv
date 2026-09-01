`timescale 1ns / 1ps

module receptor_uart #(
    parameter int FREQ_CLOCK = 50_000_000,
    parameter int TAXA_BAUD  = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] dado_recebido,
    output logic       dado_valido
);

    localparam int CLOCKS_POR_BIT = FREQ_CLOCK / TAXA_BAUD;

    typedef enum logic [1:0] {
        OCIOSO = 2'b00,
        INICIO = 2'b01,
        DADOS  = 2'b10,
        PARADA = 2'b11
    } estado_t;

    estado_t estado_atual;

    logic [15:0] contador_clock;
    logic [2:0]  indice_bit;
    logic [7:0]  registro_dado;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            estado_atual   <= OCIOSO;
            contador_clock <= 16'd0;
            indice_bit     <= 3'd0;
            registro_dado  <= 8'd0;
            dado_recebido  <= 8'd0;
            dado_valido    <= 1'b0;
        end else begin

            dado_valido <= 1'b0;

            case (estado_atual)

                OCIOSO: begin
                    contador_clock <= 16'd0;
                    indice_bit     <= 3'd0;
                    if (rx == 1'b0) begin
                        estado_atual <= INICIO;
                    end else begin
                        estado_atual <= OCIOSO;
                    end
                end

                INICIO: begin
                    if (contador_clock == (CLOCKS_POR_BIT / 2)) begin
                        if (rx == 1'b0) begin
                            contador_clock <= 16'd0;
                            estado_atual   <= DADOS;
                        end else begin
                            estado_atual <= OCIOSO;
                        end
                    end else begin
                        contador_clock <= contador_clock + 16'd1;
                        estado_atual   <= INICIO;
                    end
                end

                DADOS: begin
                    if (contador_clock < CLOCKS_POR_BIT - 1) begin
                        contador_clock <= contador_clock + 16'd1;
                        estado_atual   <= DADOS;
                    end else begin
                        contador_clock <= 16'd0;
                        registro_dado[indice_bit] <= rx;
                        
                        if (indice_bit < 7) begin
                            indice_bit   <= indice_bit + 3'd1;
                            estado_atual <= DADOS;
                        end else begin
                            indice_bit   <= 3'd0;
                            estado_atual <= PARADA;
                        end
                    end
                end

                PARADA: begin
                    if (contador_clock < CLOCKS_POR_BIT - 1) begin
                        contador_clock <= contador_clock + 16'd1;
                        estado_atual   <= PARADA;
                    end else begin
                        dado_valido    <= 1'b1;
                        dado_recebido  <= registro_dado;
                        contador_clock <= 16'd0;
                        estado_atual   <= OCIOSO;
                    end
                end

                default: estado_atual <= OCIOSO;
            endcase
        end
    end

endmodule