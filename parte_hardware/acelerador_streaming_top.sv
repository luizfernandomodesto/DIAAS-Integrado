`timescale 1ns / 1ps

// Liga tudo: recebe pela UART, guarda no buffer circular, multiplica pelos
// pesos, acumula, e sinaliza quando o resultado de cada amostra fica pronto.
module acelerador_streaming_top #(
    parameter int FREQ_CLOCK = 50_000_000,
    parameter int TAXA_BAUD  = 115200,
    parameter int NUMTAPS    = 127
)(
    input  logic clk,
    input  logic rst_n,
    input  logic rx,
    output logic tx
);

    logic [7:0]  fio_dado_rx_8b;
    logic        fio_dado_valido_8b;
    logic [31:0] fio_dado_32b;
    logic        fio_dado_valido_32b;

    logic                       fio_hab_escrita_buffer;
    logic [$clog2(NUMTAPS)-1:0] fio_endereco_escrita_buffer;
    logic [$clog2(NUMTAPS)-1:0] fio_endereco_leitura_buffer;
    logic [$clog2(NUMTAPS)-1:0] fio_endereco_leitura_pesos;
    logic                       fio_hab_mac;
    logic                       fio_limpa_mac;
    logic                       fio_resultado_pronto;

    logic [31:0] fio_dado_buffer;
    logic [31:0] fio_peso_rom;
    logic [63:0] fio_acumulador;

    logic        fio_inicia_tx;
    logic [7:0]  fio_dado_tx;
    logic        fio_tx_ocupado;

    receptor_uart #(
        .FREQ_CLOCK(FREQ_CLOCK),
        .TAXA_BAUD(TAXA_BAUD)
    ) rx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .dado_recebido(fio_dado_rx_8b),
        .dado_valido(fio_dado_valido_8b)
    );

    empacotador_bytes empacotador_inst (
        .clk(clk),
        .rst_n(rst_n),
        .dado_valido_8b(fio_dado_valido_8b),
        .dado_8b(fio_dado_rx_8b),
        .dado_valido_32b(fio_dado_valido_32b),
        .dado_32b(fio_dado_32b)
    );

    memoria_circular #(
        .LARGURA_DADO(32),
        .PROFUNDIDADE(NUMTAPS)
    ) buffer_inst (
        .clk(clk),
        .rst_n(rst_n),
        .habilita_escrita(fio_hab_escrita_buffer),
        .endereco_escrita(fio_endereco_escrita_buffer),
        .dado_entrada(fio_dado_32b),
        .endereco_leitura(fio_endereco_leitura_buffer),
        .dado_saida(fio_dado_buffer)
    );

    memoria_pesos #(
        .LARGURA_DADO(32),
        .PROFUNDIDADE(NUMTAPS)
    ) rom_pesos_inst (
        .clk(clk),
        .endereco(fio_endereco_leitura_pesos),
        .dado_saida(fio_peso_rom)
    );

    mac_dsp_streaming mac_inst (
        .clk(clk),
        .rst_n(rst_n),
        .habilita(fio_hab_mac),
        .limpa(fio_limpa_mac),
        .peso(fio_peso_rom),
        .dado_in(fio_dado_buffer),
        .acumulador(fio_acumulador)
    );

    controlador_fsm_streaming #(
        .NUMTAPS(NUMTAPS)
    ) fsm_inst (
        .clk(clk),
        .rst_n(rst_n),
        .dado_valido_32b(fio_dado_valido_32b),
        .habilita_escrita_buffer(fio_hab_escrita_buffer),
        .endereco_escrita_buffer(fio_endereco_escrita_buffer),
        .endereco_leitura_buffer(fio_endereco_leitura_buffer),
        .endereco_leitura_pesos(fio_endereco_leitura_pesos),
        .habilita_mac(fio_hab_mac),
        .limpa_mac(fio_limpa_mac),
        .resultado_pronto(fio_resultado_pronto)
    );

    transmissor_uart #(
        .FREQ_CLOCK(FREQ_CLOCK),
        .TAXA_BAUD(TAXA_BAUD)
    ) tx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .inicia_tx(fio_inicia_tx),
        .dado_tx(fio_dado_tx),
        .tx(tx),
        .ocupado(fio_tx_ocupado)
    );

    // tx nao e usado - o testbench le fio_acumulador direto, sem
    // precisar transmitir o resultado de volta pela serial
    assign fio_inicia_tx = 1'b0;
    assign fio_dado_tx   = 8'd0;

endmodule
