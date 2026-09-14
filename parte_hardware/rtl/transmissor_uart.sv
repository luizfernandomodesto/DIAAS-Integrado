`timescale 1ns / 1ps

module transmissor_uart #(
    parameter int FREQ_CLOCK = 50_000_000,
    parameter int TAXA_BAUD  = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       inicia_tx,
    input  logic [7:0] dado_tx,
    output logic       tx,
    output logic       ocupado
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
            tx             <= 1'b1;
            ocupado        <= 1'b0;
        end else begin
            case (estado_atual)

                OCIOSO: begin
                    tx      <= 1'b1;
                    ocupado <= 1'b0;
                    if (inicia_tx) begin
                        registro_dado  <= dado_tx;
                        estado_atual   <= INICIO;
                        contador_clock <= 16'd0;
                        ocupado        <= 1'b1;
                    end
                end

                INICIO: begin
                    tx <= 1'b0;
                    if (contador_clock < CLOCKS_POR_BIT - 1) begin
                        contador_clock <= contador_clock + 16'd1;
                    end else begin
                        contador_clock <= 16'd0;
                        estado_atual   <= DADOS;
                        indice_bit     <= 3'd0;
                    end
                end

                DADOS: begin
                    tx <= registro_dado[indice_bit];
                    if (contador_clock < CLOCKS_POR_BIT - 1) begin
                        contador_clock <= contador_clock + 16'd1;
                    end else begin
                        contador_clock <= 16'd0;
                        if (indice_bit < 7) begin
                            indice_bit <= indice_bit + 3'd1;
                        end else begin
                            estado_atual <= PARADA;
                        end
                    end
                end

                PARADA: begin
                    tx <= 1'b1;
                    if (contador_clock < CLOCKS_POR_BIT - 1) begin
                        contador_clock <= contador_clock + 16'd1;
                    end else begin
                        contador_clock <= 16'd0;
                        estado_atual   <= OCIOSO;
                    end
                end

                default: estado_atual <= OCIOSO;
            endcase
        end
    end

endmodule