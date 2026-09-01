`timescale 1ns / 1ps

module acelerador_top #(
    parameter int FREQ_CLOCK = 50_000_000,
    parameter int TAXA_BAUD  = 115200,
    parameter int PROF_MEM   = 1024
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
    logic        fio_hab_escrita;
    logic        fio_hab_leitura;
    logic        fio_hab_mac;
    logic        fio_limpa_mac;
    logic        fio_fim_calculo;
    logic [31:0] fio_dado_bram;
    logic [31:0] fio_peso_bram;
    logic [63:0] fio_acumulador;
    logic        fio_inicia_tx;
    logic [7:0]  fio_dado_tx;
    logic        fio_tx_ocupado;
    
    logic [$clog2(PROF_MEM)-1:0] endereco_escrita;
    logic [$clog2(PROF_MEM)-1:0] endereco_leitura;
    logic [$clog2(PROF_MEM)-1:0] endereco_bram_imagem;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            endereco_escrita <= '0;
        end else if (fio_hab_escrita) begin
            endereco_escrita <= endereco_escrita + 1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            endereco_leitura <= '0;
        end else if (fio_hab_leitura) begin
            endereco_leitura <= endereco_leitura + 1;
        end
    end

    assign endereco_bram_imagem = (fio_hab_leitura) ? endereco_leitura : endereco_escrita;

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

    memoria_bram #(
        .LARGURA_DADO(32),
        .PROFUNDIDADE(PROF_MEM)
    ) bram_imagem_inst (
        .clk(clk),
        .habilita_escrita(fio_hab_escrita),
        .endereco(endereco_bram_imagem),
        .dado_entrada(fio_dado_32b),
        .dado_saida(fio_dado_bram)
    );

    memoria_pesos #(
        .LARGURA_DADO(32),
        .PROFUNDIDADE(PROF_MEM)
    ) rom_pesos_inst (
        .clk(clk),
        .endereco(endereco_leitura), 
        .dado_saida(fio_peso_bram)
    );

    mac_dsp mac_inst (
        .clk(clk),
        .rst_n(rst_n),
        .habilita(fio_hab_mac),
        .limpa(fio_limpa_mac),
        .peso(fio_peso_bram),
        .dado_in(fio_dado_bram),
        .acumulador(fio_acumulador)
    );

    controlador_fsm fsm_inst (
        .clk(clk),
        .rst_n(rst_n),
        .dado_valido_32b(fio_dado_valido_32b),
        .fim_calculo(fio_fim_calculo),
        .habilita_escrita(fio_hab_escrita),
        .habilita_leitura(fio_hab_leitura),
        .habilita_mac(fio_hab_mac),
        .limpa_mac(fio_limpa_mac)
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

    assign fio_fim_calculo = (endereco_leitura == 10'd1023); 
    assign fio_inicia_tx   = 1'b0;   
    assign fio_dado_tx     = 8'd0;     

endmodule